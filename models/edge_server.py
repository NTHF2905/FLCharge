"""
edge_server.py  (phiên bản DQN + metric tracking)
----------------------------------------------------------------
Lớp Edge cho MỘT cụm chargerbot (dùng chung edge_id). Hai vai trò:

  1. TCP SERVER hướng về GAMA
     chargerbot connect vào cổng 3001 (raw TCP, JSON nối tiếp).
  2. TCP CLIENT hướng về cloud_server.py (cổng 4001).
     Định kỳ gửi experience + weight, nhận weight mới.

BỔ SUNG so với bản cũ:
  • DQN agent (PyTorch) ra quyết định "continue / return_to_base"
    dựa trên vector trạng thái 8 chiều.
  • BotMetrics theo dõi mỗi chargerbot: runtime, quãng đường,
    số xe phục vụ, số lần sạc, tổng thời gian sạc.
  • Protocol mở rộng:
        GAMA → Edge : metrics_update, job_completed,
                      recharge_start, recharge_end, metrics_query
        Edge → GAMA : metrics_report
  • Reward tự suy ra từ delta metric giữa hai lần battery_check.

Chạy: python edge_server.py
Thứ tự: cloud_server.py → edge_server.py → GAMA simulation
----------------------------------------------------------------
"""

import socket
import threading
import json
import time
import os
import random
from collections import deque
from dataclasses import dataclass, field, asdict

# ============================================================
# CẤU HÌNH
# ============================================================
EDGE_ID = "edge_01"
GAMA_LISTEN_PORT = 3001
CLOUD_HOST = "localhost"
CLOUD_PORT = 4001
REPORT_EVERY_N_REQUESTS = 20

# DQN hyperparameters
STATE_DIM = 8
ACTION_DIM = 2                     # 0 = continue, 1 = return_to_base
HIDDEN_DIM = 64
GAMMA = 0.95
LR = 1e-3
BATCH_SIZE = 32
REPLAY_CAPACITY = 5000
TRAIN_EVERY_N_STEPS = 4
TARGET_UPDATE_EVERY = 100
EPSILON_START = 1.0
EPSILON_END = 0.05
EPSILON_DECAY_STEPS = 3000
CHECKPOINT_PATH = "edge_dqn.pt"

# Rule-based fallback khi không có PyTorch
BATTERY_LOW_THRESHOLD = 25.0
MIN_SAFETY_MARGIN = 5.0

lock = threading.Lock()
local_weights = [1.0, 1.0, 1.0, 1.0]
weight_version = 0
experience_buffer = []

# ============================================================
# PYTORCH (graceful fallback)
# ============================================================
try:
    import torch
    import torch.nn as nn
    import torch.optim as optim
    TORCH_AVAILABLE = True
except ImportError:
    TORCH_AVAILABLE = False
    print("[edge] CẢNH BÁO: PyTorch không có sẵn → fallback rule-based")


# ============================================================
# METRICS MỖI CHARGERBOT
# ============================================================
@dataclass
class BotMetrics:
    bot_id: str
    connected_at: float = field(default_factory=time.time)
    last_seen: float = field(default_factory=time.time)
    total_distance_m: float = 0.0          # quãng đường tích luỹ
    cars_served: int = 0                    # số xe đã phục vụ
    recharge_count: int = 0                 # số lần tự sạc
    total_recharge_seconds: float = 0.0     # tổng thời gian sạc
    current_battery: float = 100.0
    state: str = "idle"                     # idle/serving/returning/recharging
    jobs_in_session: int = 0
    time_since_last_recharge: float = 0.0
    recharge_started_at: float = 0.0        # 0 = không đang sạc
    last_recharge_duration: float = 0.0

    def runtime_seconds(self) -> float:
        return time.time() - self.connected_at

    def to_report(self) -> dict:
        avg = (self.total_recharge_seconds / self.recharge_count
               if self.recharge_count > 0 else 0.0)
        return {
            "bot_id": self.bot_id,
            "runtime_seconds": round(self.runtime_seconds(), 1),
            "distance_km": round(self.total_distance_m / 1000.0, 3),
            "cars_served": self.cars_served,
            "recharge_count": self.recharge_count,
            "total_recharge_seconds": round(self.total_recharge_seconds, 1),
            "avg_recharge_seconds": round(avg, 1),
            "current_battery": round(self.current_battery, 1),
            "state": self.state,
            "jobs_in_session": self.jobs_in_session,
        }


metrics_by_bot: dict[str, BotMetrics] = {}
metrics_lock = threading.Lock()


def get_or_create_metrics(bot_id: str) -> BotMetrics:
    with metrics_lock:
        if bot_id not in metrics_by_bot:
            metrics_by_bot[bot_id] = BotMetrics(bot_id=bot_id)
        return metrics_by_bot[bot_id]


# ============================================================
# DQN AGENT
# ============================================================
class ReplayBuffer:
    def __init__(self, capacity: int):
        self.buf = deque(maxlen=capacity)

    def push(self, s, a, r, s2, done):
        self.buf.append((s, a, r, s2, done))

    def sample(self, n):
        batch = random.sample(self.buf, n)
        s, a, r, s2, d = zip(*batch)
        return s, a, r, s2, d

    def __len__(self):
        return len(self.buf)


if TORCH_AVAILABLE:
    class QNetwork(nn.Module):
        def __init__(self, state_dim, action_dim, hidden):
            super().__init__()
            self.net = nn.Sequential(
                nn.Linear(state_dim, hidden), nn.ReLU(),
                nn.Linear(hidden, hidden),    nn.ReLU(),
                nn.Linear(hidden, action_dim),
            )

        def forward(self, x):
            return self.net(x)

# ============================================================
# SERIALIZE / DESERIALIZE STATE_DICT (JSON-friendly)
# ============================================================
def serialize_state_dict(sd) -> dict:
    """OrderedDict[str, Tensor] → dict[str, nested_list]."""
    if not TORCH_AVAILABLE or sd is None:
        return {}
    return {k: v.detach().cpu().numpy().tolist() for k, v in sd.items()}


def deserialize_state_dict(sd_dict) -> dict:
    """dict[str, nested_list] → dict[str, Tensor] cho load_state_dict()."""
    if not TORCH_AVAILABLE or not sd_dict:
        return {}
    return {k: torch.tensor(v, dtype=torch.float32) for k, v in sd_dict.items()}


class DQNAgent:
    """DQN cho quyết định continue/return_to_base của chargerbot."""

    def __init__(self):
        self.steps = 0
        self.episodes = 0
        self.total_reward = 0.0
        self.loss_history = deque(maxlen=100)

        if TORCH_AVAILABLE:
            self.device = torch.device("cpu")
            self.q = QNetwork(STATE_DIM, ACTION_DIM, HIDDEN_DIM).to(self.device)
            self.q_target = QNetwork(STATE_DIM, ACTION_DIM, HIDDEN_DIM).to(self.device)
            self.q_target.load_state_dict(self.q.state_dict())
            self.opt = optim.Adam(self.q.parameters(), lr=LR)
            self.buffer = ReplayBuffer(REPLAY_CAPACITY)
            self._load_checkpoint()

    # -------- chọn action --------
    def select_action(self, state_vec, greedy=False):
        eps = self._epsilon()
        if TORCH_AVAILABLE:
            if not greedy and random.random() < eps:
                return random.randrange(ACTION_DIM)
            with torch.no_grad():
                x = torch.tensor(state_vec, dtype=torch.float32,
                                 device=self.device).unsqueeze(0)
                return int(self.q(x).argmax(dim=1).item())
        else:
            # fallback rule-based: chỉ dùng feature battery (index 0)
            battery = state_vec[0] * 100.0
            return 1 if battery < BATTERY_LOW_THRESHOLD else 0

    def _epsilon(self):
        if self.steps >= EPSILON_DECAY_STEPS:
            return EPSILON_END
        frac = self.steps / EPSILON_DECAY_STEPS
        return EPSILON_START + frac * (EPSILON_END - EPSILON_START)

    # -------- lưu experience + train --------
    def store(self, s, a, r, s2, done):
        if not TORCH_AVAILABLE:
            return
        self.buffer.push(s, a, r, s2, done)
        self.total_reward += r
        if done:
            self.episodes += 1

    def train_step(self):
        if not TORCH_AVAILABLE or len(self.buffer) < BATCH_SIZE:
            return
        self.steps += 1
        if self.steps % TRAIN_EVERY_N_STEPS != 0:
            return

        s, a, r, s2, d = self.buffer.sample(BATCH_SIZE)
        s = torch.tensor(s, dtype=torch.float32, device=self.device)
        a = torch.tensor(a, dtype=torch.long,    device=self.device).unsqueeze(1)
        r = torch.tensor(r, dtype=torch.float32, device=self.device).unsqueeze(1)
        s2 = torch.tensor(s2, dtype=torch.float32, device=self.device)
        d = torch.tensor(d, dtype=torch.float32, device=self.device).unsqueeze(1)

        q_vals = self.q(s).gather(1, a)
        with torch.no_grad():
            q_next = self.q_target(s2).max(dim=1, keepdim=True)[0]
            target = r + GAMMA * q_next * (1 - d)

        loss = nn.functional.mse_loss(q_vals, target)
        self.opt.zero_grad()
        loss.backward()
        nn.utils.clip_grad_norm_(self.q.parameters(), 1.0)
        self.opt.step()
        self.loss_history.append(loss.item())

        if self.steps % TARGET_UPDATE_EVERY == 0:
            self.q_target.load_state_dict(self.q.state_dict())
            self._save_checkpoint()

    # -------- checkpoint --------
    def _save_checkpoint(self):
        if not TORCH_AVAILABLE:
            return
        try:
            torch.save({
                "q": self.q.state_dict(),
                "q_target": self.q_target.state_dict(),
                "steps": self.steps,
                "episodes": self.episodes,
            }, CHECKPOINT_PATH)
        except OSError as e:
            print(f"[edge] không lưu được checkpoint: {e}")

    def _load_checkpoint(self):
        if not TORCH_AVAILABLE or not os.path.exists(CHECKPOINT_PATH):
            return
        try:
            ckpt = torch.load(CHECKPOINT_PATH, map_location=self.device)
            self.q.load_state_dict(ckpt["q"])
            self.q_target.load_state_dict(ckpt["q_target"])
            self.steps = ckpt.get("steps", 0)
            self.episodes = ckpt.get("episodes", 0)
            print(f"[edge] nạp DQN checkpoint: steps={self.steps}")
        except (OSError, KeyError) as e:
            print(f"[edge] không nạp được checkpoint: {e}")

    def stats(self) -> dict:
        avg_loss = (sum(self.loss_history) / len(self.loss_history)
                    if self.loss_history else 0.0)
        return {
            "steps": self.steps,
            "episodes": self.episodes,
            "epsilon": round(self._epsilon(), 4),
            "avg_loss": round(avg_loss, 5),
            "buffer_size": len(self.buffer) if TORCH_AVAILABLE else 0,
            "total_reward": round(self.total_reward, 3),
        }


dqn = DQNAgent()


# ============================================================
# XÂY DỰNG VECTOR TRẠNG THÁI + REWARD
# ============================================================
def build_state_vector(msg: dict, m: BotMetrics) -> list:
    """8 chiều: pin, khoảng cách trạm gần, thời gian từ lần sạc cuối,
    job trong session, queue, giờ trong ngày, quãng đường, số lần sạc."""
    battery = msg.get("battery_level", 100.0)
    dist = msg.get("nearest_station_distance", 0.0)
    queue = msg.get("queue_len", 0)
    hour = msg.get("hour_of_day", 12)
    return [
        battery / 100.0,
        min(dist / 1000.0, 2.0),
        min(m.time_since_last_recharge / 3600.0, 5.0),
        min(m.jobs_in_session / 20.0, 1.0),
        min(queue / 10.0, 1.0),
        hour / 24.0,
        min(m.total_distance_m / 50000.0, 1.0),
        min(m.recharge_count / 10.0, 1.0),
    ]


def compute_reward(prev: dict, curr_metrics: BotMetrics,
                   curr_battery: float) -> float:
    """
    Reward suy ra từ delta metric giữa hai lần battery_check.
    prev = {"metrics": BotMetrics snapshot, "action": int, "timestamp": float}
    """
    prev_m = prev["metrics"]
    action = prev["action"]
    dt = max(time.time() - prev["timestamp"], 1e-6)

    jobs_delta = curr_metrics.cars_served - prev_m["cars_served"]
    dist_delta = curr_metrics.total_distance_m - prev_m["total_distance_m"]
    recharged = curr_metrics.recharge_count > prev_m["recharge_count"]

    r = 0.0
    r += jobs_delta * 2.0                          # thưởng năng suất
    r -= (dist_delta / 1000.0) * 0.05              # phạt quãng đường (hiệu suất)
    if curr_battery < 10.0:
        r -= 5.0                                   # nguy hiểm: pin cạn
    elif curr_battery < 25.0:
        r -= 1.0
    if recharged and curr_battery > 50.0:
        r += 1.5                                   # sạc thành công, an toàn
    if action == 0 and jobs_delta == 0 and dt > 600:
        r -= 0.5                                   # phạt idle khi pin còn tốt
    return r


# Per-bot transition cache cho DQN
bot_transitions: dict[str, dict] = {}
transition_lock = threading.Lock()


# ============================================================
# JSON STREAM PARSER
# ============================================================
def parse_json_stream(buffer: str):
    decoder = json.JSONDecoder()
    messages = []
    idx = 0
    n = len(buffer)
    while idx < n:
        while idx < n and buffer[idx] in " \t\r\n":
            idx += 1
        if idx >= n:
            break
        try:
            obj, end = decoder.raw_decode(buffer, idx)
        except json.JSONDecodeError:
            break
        messages.append(obj)
        idx = end
    return messages, buffer[idx:]


# ============================================================
# HANDLERS TỪNG LOẠI MESSAGE
# ============================================================
def handle_charge_request(msg: dict, conn: socket.socket):
    features = msg.get("features", {})
    with lock:
        w = list(local_weights)
    distance = max(features.get("distance", 1.0), 0.1)
    slot_ratio = features.get("slot_ratio", 0.5)
    queue_len = max(features.get("queue_len", 1), 1)
    price_factor = features.get("price_factor", 1.0)
    score = (w[0] * (1.0 / distance) + w[1] * slot_ratio
             + w[2] * (1.0 / queue_len) + w[3] * price_factor)

    response = {
        "type": "charge_response",
        "request_id": msg.get("request_id"),
        "target_station_id": msg.get("candidate_station_id", "CS_UNKNOWN"),
        "score": score,
    }
    conn.sendall(json.dumps(response).encode("utf-8"))

    with lock:
        experience_buffer.append({"features": features, "score": score})
        should_report = len(experience_buffer) >= REPORT_EVERY_N_REQUESTS
    if should_report:
        threading.Thread(target=report_to_cloud, daemon=True).start()


def handle_battery_check(msg: dict, conn: socket.socket):
    """Quyết định continue/return_to_base bằng DQN + cập nhật transition."""
    bot_id = msg.get("bot_id", "unknown")
    m = get_or_create_metrics(bot_id)
    m.last_seen = time.time()
    m.current_battery = msg.get("battery_level", 100.0)
    m.time_since_last_recharge += max(
        time.time() - (m.last_seen or time.time()), 0.0)

    state_vec = build_state_vector(msg, m)

    # -- Nếu có transition trước đó → tính reward, lưu vào DQN, train
    with transition_lock:
        prev = bot_transitions.get(bot_id)
    if prev is not None:
        reward = compute_reward(prev, m, m.current_battery)
        done = (m.current_battery >= 99.0 and m.state == "recharging")
        dqn.store(prev["state"], prev["action"], reward, state_vec, done)
        dqn.train_step()

    # -- Chọn action mới
    action = dqn.select_action(state_vec)
    with transition_lock:
        bot_transitions[bot_id] = {
            "state": state_vec,
            "action": action,
            "timestamp": time.time(),
            "metrics": {
                "cars_served": m.cars_served,
                "total_distance_m": m.total_distance_m,
                "recharge_count": m.recharge_count,
            },
        }

    decision = "continue" if action == 0 else "return_to_base"
    response = {
        "type": "battery_decision",
        "request_id": msg.get("request_id"),
        "action": decision,
    }
    conn.sendall(json.dumps(response).encode("utf-8"))
    print(f"[edge] battery_check bot={bot_id} "
          f"battery={m.current_battery:.1f}% state={m.state} -> {decision}")


def handle_metrics_update(msg: dict):
    bot_id = msg.get("bot_id", "unknown")
    m = get_or_create_metrics(bot_id)
    m.last_seen = time.time()
    m.total_distance_m += msg.get("distance_delta", 0.0)
    if "state" in msg:
        m.state = msg["state"]


def handle_job_completed(msg: dict):
    bot_id = msg.get("bot_id", "unknown")
    m = get_or_create_metrics(bot_id)
    m.cars_served += 1
    m.jobs_in_session += 1


def handle_recharge_start(msg: dict):
    bot_id = msg.get("bot_id", "unknown")
    m = get_or_create_metrics(bot_id)
    m.state = "recharging"
    m.recharge_started_at = time.time()


def handle_recharge_end(msg: dict):
    bot_id = msg.get("bot_id", "unknown")
    m = get_or_create_metrics(bot_id)
    if m.recharge_started_at > 0:
        dur = time.time() - m.recharge_started_at
        m.total_recharge_seconds += dur
        m.last_recharge_duration = dur
    m.recharge_count += 1
    m.recharge_started_at = 0.0
    m.time_since_last_recharge = 0.0
    m.jobs_in_session = 0
    m.state = "idle"


def handle_metrics_query(msg: dict, conn: socket.socket):
    """Truy hồi thông số. bot_id='*' trả về tất cả."""
    bot_id = msg.get("bot_id", "*")
    with metrics_lock:
        if bot_id == "*":
            report = [m.to_report() for m in metrics_by_bot.values()]
        else:
            m = metrics_by_bot.get(bot_id)
            report = [m.to_report()] if m else []
    response = {
        "type": "metrics_report",
        "request_id": msg.get("request_id"),
        "dqn": dqn.stats(),
        "bots": report,
    }
    conn.sendall(json.dumps(response).encode("utf-8"))


# ============================================================
# DISPATCHER
# ============================================================
HANDLERS_WITH_CONN = {
    "charge_request": handle_charge_request,
    "battery_check": handle_battery_check,
    "metrics_query": handle_metrics_query,
}
HANDLERS_NO_CONN = {
    "metrics_update": handle_metrics_update,
    "job_completed": handle_job_completed,
    "recharge_start": handle_recharge_start,
    "recharge_end": handle_recharge_end,
}


def handle_gama_client(conn: socket.socket, addr):
    print(f"[edge] chargerbot connected from {addr}")
    buffer = ""
    with conn:
        while True:
            data = conn.recv(4096)
            if not data:
                break
            buffer += data.decode("utf-8", errors="ignore")
            messages, buffer = parse_json_stream(buffer)
            for msg in messages:
                msg_type = msg.get("type")
                try:
                    if msg_type in HANDLERS_WITH_CONN:
                        HANDLERS_WITH_CONN[msg_type](msg, conn)
                    elif msg_type in HANDLERS_NO_CONN:
                        HANDLERS_NO_CONN[msg_type](msg)
                    else:
                        print(f"[edge] message không rõ loại: {msg_type}")
                except Exception as e:
                    print(f"[edge] lỗi xử lý {msg_type}: {e}")
    print(f"[edge] chargerbot {addr} disconnected")


# ============================================================
# ĐỒNG BỘ CLOUD
# ============================================================
def report_to_cloud():
    global local_weights, weight_version, experience_buffer

    with lock:
        buffered = experience_buffer
        experience_buffer = []

    if not buffered:
        return

    # Đính kèm snapshot metric + DQN stats để cloud theo dõi sức khoẻ
    with metrics_lock:
        metrics_snapshot = [m.to_report() for m in metrics_by_bot.values()]

    report = {
        "type": "edge_report",
        "edge_id": EDGE_ID,
        "n_samples": len(buffered),
        "avg_score": sum(e["score"] for e in buffered) / len(buffered),
        "local_weights": local_weights,
        "dqn_stats": dqn.stats(),
        "bot_metrics": metrics_snapshot,
        "dqn_state_dict": serialize_state_dict(dqn.q.state_dict()),   # ← THÊM DÒNG NÀY
    }

    try:
        with socket.create_connection((CLOUD_HOST, CLOUD_PORT), timeout=5) as s:
            s.sendall(json.dumps(report).encode("utf-8"))
            raw = s.recv(65536).decode("utf-8")
            messages, _ = parse_json_stream(raw)
            for update in messages:
                if update.get("type") == "weight_update":
                    with lock:
                        local_weights = update["weights"]
                        weight_version = update["version"]
                    print(f"[edge] weights updated -> v{weight_version}: {local_weights}")

                    # ← THÊM ĐOẠN NÀY
                    sd = update.get("dqn_state_dict")
                    if sd and TORCH_AVAILABLE:
                        try:
                            dqn.q.load_state_dict(deserialize_state_dict(sd))
                            dqn.q_target.load_state_dict(dqn.q.state_dict())
                            print(f"[edge] DQN global model loaded "
                                  f"(dqn_v{update.get('dqn_version')}, "
                                  f"n_edges={update.get('n_edges')})")
                        except (RuntimeError, KeyError) as e:
                            print(f"[edge] không nạp được global DQN: {e}")
    except (ConnectionRefusedError, socket.timeout, OSError) as e:
        print(f"[edge] không kết nối được cloud, giữ weight cũ: {e}")


# ============================================================
# MAIN
# ============================================================
def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", GAMA_LISTEN_PORT))
    server.listen(5)
    print(f"[edge] {EDGE_ID} lắng nghe GAMA tại cổng {GAMA_LISTEN_PORT}")
    print(f"[edge] DQN available: {TORCH_AVAILABLE}")
    print("[edge] hãy chắc chắn script này chạy TRƯỚC khi start simulation GAMA")
    try:
        while True:
            conn, addr = server.accept()
            threading.Thread(target=handle_gama_client,
                             args=(conn, addr), daemon=True).start()
    except KeyboardInterrupt:
        print("\n[edge] đang tắt...")
        dqn._save_checkpoint()
        server.close()


if __name__ == "__main__":
    main()
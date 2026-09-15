"""
cloud_server.py
----------------------------------------------------------------
Bộ tổng hợp trung tâm với Federated Averaging cho DQN.

Kiến trúc:
  • Mỗi edge_server.py chạy một DQN cục bộ (Q-network cho quyết định
    continue/return_to_base của chargerbot).
  • Cloud nhận báo cáo định kỳ (edge_report) gồm:
      - local_weights   : scoring 4-dim (cũ)
      - dqn_state_dict  : Q-network params dạng nested list (JSON-friendly)
      - n_samples, dqn_stats, bot_metrics
  • Cloud chạy Federated Averaging:
        θ_global = Σ_k (n_k / N) · θ_k
    cho từng tensor và từng chiều scoring. n_k = số experience đã tích luỹ
    trên edge k (mẫu càng nhiều → đóng góp càng lớn).
  • Phát global model + version trong cùng kết nối.
  • Giám sát: in tóm tắt mỗi 30 giây, hỗ trợ stats_query.

Nâng cấp sau: thay fedavg_state_dict() bằng FedAvgM / FedProx / Krum.

Chạy: python cloud_server.py   (khởi động TRƯỚC edge_server.py)
----------------------------------------------------------------
"""

import socket
import threading
import json
import time
from typing import Optional

# ============================================================
# CẤU HÌNH
# ============================================================
CLOUD_PORT = 4001
MIN_EDGES_FOR_AGG = 1        # FedAvg chạy khi có >= N edge báo cáo
STATS_PRINT_EVERY = 30       # giây — in tóm tắt trạng thái cloud
MAX_REPORT_BYTES = 1 << 20   # 1 MB — đủ cho Q-network nhỏ

# ============================================================
# TRẠNG THÁI TOÀN CỤC
# ============================================================
lock = threading.Lock()

# Scoring weights (4-dim) — dùng cho charge_request routing
global_weights = [1.0, 1.0, 1.0, 1.0]
version = 0

# DQN global model — state_dict dạng nested list
global_state_dict: Optional[dict] = None
dqn_version = 0

# Sổ sách edge
edge_reports: dict = {}      # edge_id -> report gần nhất
edge_last_seen: dict = {}    # edge_id -> timestamp

start_time = time.time()
total_reports = 0
last_stats_print = 0.0


# ============================================================
# PARSER JSON STREAM
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
# FEDAVG PRIMITIVES
# ============================================================
def _weighted_avg_scalars(values, weights):
    return sum(v * w for v, w in zip(values, weights))


def _weighted_avg_nested(arrays, weights):
    """
    Weighted average của nested list (mọi array cùng shape).
    arrays: list[nested_list], weights: list[float] với sum = 1.
    """
    if not arrays:
        return None
    head = arrays[0]
    if isinstance(head, list):
        return [
            _weighted_avg_nested([a[i] for a in arrays], weights)
            for i in range(len(head))
        ]
    return _weighted_avg_scalars(arrays, weights)


def _same_shape(a, b) -> bool:
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(_same_shape(x, y) for x, y in zip(a, b))
    return (not isinstance(a, list)) and (not isinstance(b, list))


def fedavg_scoring_weights(reports: dict):
    """Trung bình có trọng số theo n_samples cho scoring vector."""
    valid = {eid: r for eid, r in reports.items() if r.get("local_weights")}
    if not valid:
        return None
    total = sum(max(r.get("n_samples", 1), 1) for r in valid.values())
    weights = [max(r.get("n_samples", 1), 1) / total for r in valid.values()]
    dims = len(next(iter(valid.values()))["local_weights"])
    out = [0.0] * dims
    for r, w in zip(valid.values(), weights):
        for i in range(dims):
            out[i] += r["local_weights"][i] * w
    return out


def fedavg_state_dict(reports: dict):
    """
    Federated averaging của Q-network state_dict (nested list).
    Chỉ tổng hợp các edge có state_dict cùng kiến trúc.
    """
    valid = {eid: r for eid, r in reports.items() if r.get("dqn_state_dict")}
    if not valid:
        return None

    # Lọc edge cùng shape với edge đầu tiên
    ref_eid = next(iter(valid))
    ref_sd = valid[ref_eid]["dqn_state_dict"]
    same = [eid for eid, r in valid.items()
            if all(_same_shape(r["dqn_state_dict"][k], ref_sd[k]) for k in ref_sd)]

    if len(same) < len(valid):
        skipped = set(valid) - set(same)
        print(f"[cloud] bỏ qua {len(skipped)} edge kiến trúc khác: {skipped}")
    if not same:
        return None

    total = sum(max(valid[eid].get("n_samples", 1), 1) for eid in same)
    weights = [max(valid[eid].get("n_samples", 1), 1) / total for eid in same]

    aggregated = {}
    for k in ref_sd.keys():
        arrays = [valid[eid]["dqn_state_dict"][k] for eid in same]
        aggregated[k] = _weighted_avg_nested(arrays, weights)
    return aggregated


# ============================================================
# GIÁM SÁT / TỔNG HỢP STATS
# ============================================================
def aggregate_dqn_stats(reports: dict) -> dict:
    stats_list = [r.get("dqn_stats", {}) for r in reports.values()]
    stats_list = [s for s in stats_list if s]
    if not stats_list:
        return {}
    n = len(stats_list)
    return {
        "n_edges": n,
        "total_steps": sum(s.get("steps", 0) for s in stats_list),
        "total_episodes": sum(s.get("episodes", 0) for s in stats_list),
        "avg_epsilon": round(sum(s.get("epsilon", 0) for s in stats_list) / n, 4),
        "avg_loss": round(sum(s.get("avg_loss", 0) for s in stats_list) / n, 5),
        "total_buffer": sum(s.get("buffer_size", 0) for s in stats_list),
        "total_reward": round(sum(s.get("total_reward", 0) for s in stats_list), 2),
    }


def aggregate_bot_metrics(reports: dict) -> dict:
    tot_cars = tot_dist = tot_recharge = 0
    tot_recharge_s = 0.0
    n_bots = 0
    for r in reports.values():
        for m in r.get("bot_metrics", []) or []:
            n_bots += 1
            tot_cars += m.get("cars_served", 0)
            tot_dist += m.get("distance_km", 0.0)
            tot_recharge += m.get("recharge_count", 0)
            tot_recharge_s += m.get("total_recharge_seconds", 0.0)
    return {
        "n_bots": n_bots,
        "total_cars_served": tot_cars,
        "total_distance_km": round(tot_dist, 2),
        "total_recharges": tot_recharge,
        "total_recharge_seconds": round(tot_recharge_s, 1),
    }


def maybe_print_stats(force=False):
    global last_stats_print
    now = time.time()
    if not force and (now - last_stats_print) < STATS_PRINT_EVERY:
        return
    last_stats_print = now

    with lock:
        ds = aggregate_dqn_stats(edge_reports)
        bm = aggregate_bot_metrics(edge_reports)
        n_edges = len(edge_reports)
        v, dv = version, dqn_version

    uptime = now - start_time
    print(f"\n[cloud] === TÓM TẮT (uptime {uptime:.0f}s) ===")
    print(f"[cloud] edges={n_edges} | scoring v{v} | dqn v{dv} | reports={total_reports}")
    if ds:
        print(f"[cloud] DQN: steps={ds['total_steps']} eps={ds['total_episodes']} "
              f"ε={ds['avg_epsilon']:.3f} loss={ds['avg_loss']:.5f} "
              f"buffer={ds['total_buffer']} reward={ds['total_reward']:.2f}")
    if bm:
        print(f"[cloud] Bots: n={bm['n_bots']} cars={bm['total_cars_served']} "
              f"dist={bm['total_distance_km']}km recharges={bm['total_recharges']} "
              f"recharge_time={bm['total_recharge_seconds']}s")


# ============================================================
# XỬ LÝ KẾT NỐI TỪ EDGE
# ============================================================
def handle_edge(conn, addr):
    global global_weights, global_state_dict, version, dqn_version, total_reports

    buffer = ""
    with conn:
        conn.settimeout(10)
        try:
            data = conn.recv(MAX_REPORT_BYTES)
        except socket.timeout:
            return
        if not data:
            return
        buffer += data.decode("utf-8", errors="ignore")
        messages, _ = parse_json_stream(buffer)
        if not messages:
            print(f"[cloud] không parse được dữ liệu từ {addr}")
            return

        report = messages[0]
        msg_type = report.get("type", "")

        # ---- stats_query: client muốn xem trạng thái cloud ----
        if msg_type == "stats_query":
            with lock:
                resp = {
                    "type": "stats_report",
                    "version": version,
                    "dqn_version": dqn_version,
                    "n_edges": len(edge_reports),
                    "total_reports": total_reports,
                    "global_weights": global_weights,
                    "dqn_stats": aggregate_dqn_stats(edge_reports),
                    "bot_metrics": aggregate_bot_metrics(edge_reports),
                }
            conn.sendall(json.dumps(resp).encode("utf-8"))
            return

        # ---- edge_report: đường dẫn chính ----
        if msg_type != "edge_report":
            print(f"[cloud] message lạ từ {addr}: {msg_type}")
            return

        edge_id = report.get("edge_id", str(addr))
        n_samples = max(int(report.get("n_samples", 0)), 1)

        with lock:
            edge_reports[edge_id] = report
            edge_last_seen[edge_id] = time.time()

            # --- FedAvg scoring ---
            new_w = fedavg_scoring_weights(edge_reports)
            if new_w is not None:
                global_weights = new_w
                version += 1

            # --- FedAvg DQN ---
            new_sd = None
            if len(edge_reports) >= MIN_EDGES_FOR_AGG:
                new_sd = fedavg_state_dict(edge_reports)
            if new_sd is not None:
                global_state_dict = new_sd
                dqn_version += 1

            total_reports += 1
            v_snap, dv_snap = version, dqn_version
            gw_snap = list(global_weights)
            sd_snap = global_state_dict

        has_sd = "yes" if report.get("dqn_state_dict") else "no"
        avg_score = report.get("avg_score", 0.0)
        print(f"[cloud] {edge_id}: n={n_samples} avg_score={avg_score:.3f} "
              f"sd={has_sd} → scoring v{v_snap} / dqn v{dv_snap}")

        update = {
            "type": "weight_update",
            "weights": gw_snap,
            "version": v_snap,
            "dqn_state_dict": sd_snap,
            "dqn_version": dv_snap,
            "n_edges": len(edge_reports),
        }
        conn.sendall(json.dumps(update).encode("utf-8"))

    maybe_print_stats()


# ============================================================
# MAIN
# ============================================================
def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", CLOUD_PORT))
    server.listen(5)
    print(f"[cloud] lắng nghe edge tại cổng {CLOUD_PORT}")
    print(f"[cloud] chiến lược: FedAvg (min_edges={MIN_EDGES_FOR_AGG})")
    try:
        while True:
            conn, addr = server.accept()
            threading.Thread(target=handle_edge, args=(conn, addr), daemon=True).start()
    except KeyboardInterrupt:
        print("\n[cloud] đang tắt...")
        maybe_print_stats(force=True)
        with lock:
            print(f"[cloud] tổng kết cuối: scoring v{version} / dqn v{dqn_version}")
            print(f"[cloud]   DQN : {aggregate_dqn_stats(edge_reports)}")
            print(f"[cloud]   Bots: {aggregate_bot_metrics(edge_reports)}")
        server.close()


if __name__ == "__main__":
    main()  
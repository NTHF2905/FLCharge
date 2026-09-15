// ============================================================
// FILE: Traffic.gaml
// PURPOSE: Defines the core species, shared global variables,
//          and reusable behaviors that main.gaml builds upon.
//          This file acts as the "engine" — roads, vehicles,
//          charging stations, and buildings are all declared here.
// ============================================================

model traffic // Declares the model name; imported by main.gaml via `import "Traffic.gaml"`

global {
	// --- Time & simulation step ---
	float step <- 1.0 #m; // Each simulation step represents 1 simulated minute (#m = minute unit in GAMA)

	// --- Agent type constants (string tags for distinguishing vehicle kinds) ---
	string BOT <- "chargerbot"; // Tag for charger robots (combined with edge servers)
	string CAR <- "car";    // Tag for regular ICE (internal combustion engine) cars
	string EVS <- "elecar"; // Tag for electric vehicles (elecar species)

	// --- Road network graph ---
	graph road_network; // The directed graph built from `road` agent edges + `intersection` vertices;
	                    // used by the `driving` skill to compute shortest paths

	// --- Road geometry ---
	float lane_width <- 1.0; // Width of a single lane in meters (used for lateral positioning and lane count calculation)

	// --- Global tracking counters ---
	int batter_insufficient <- 0;           // Counts EVs that died because their battery reached 0 (stranded vehicles)
	list<point> lost_car_location <- [];    // Records the last known location of every stranded EV (for scatter-plot display)
	int vehi_capacity <- 10;               // Legacy per-station capacity cap (now overridden by per-port counts; kept as a UI parameter)

	// --- Energy model ---
	float electrical_consumption <- 11/60; // Power drawn by a charging vehicle per step: 11 kWh/h ÷ 60 steps/h = ~0.183 kWh per minute-step

	// --- Day / time tracking ---
	int day_counter <- 1;                              // Which simulation day we are on (incremented by the daily export reflex in main.gaml)
	float simulation_hour <- 0.0 update: simulation_hour + step/60;
	// simulation_hour advances by step/60 = 1/60 hours = 1 minute per step,
	// giving a continuous clock in fractional hours (e.g. 8.5 = 08:30)

	// --- Rush-hour parameters ---
	float percent_rush_hour <- 0.7; // Fraction of taxis assumed to be active during rush hour (currently informational)
	float percent_charge <- 0.7;    // Probability that a taxi will charge overnight at a depot (70% by default)
	bool proba_charging_night <- flip(percent_charge); // Random boolean: true with 70% chance — whether THIS taxi charges at night
	float proba_charge_home <- 0.0; // Legacy home-charging probability; mobile charging is the default
	float private_charge_request_threshold <- 80.0; // Private EV requests a chargerbot when parked below this SoC
	float private_charge_target_soc <- 100.0; // Private EV charge target; service may continue until departure
	float taxi_charge_request_threshold <- 30.0; // Taxi checks/requests charging after drop-off below this SoC
	float taxi_charge_target_soc <- 70.0; // Taxi target SoC before it can accept the next trip

	// --- Vehicle speed ranges (randomised at global init, used as species max_speed) ---
	float bot_speed <- rnd(6.0, 7.0);
	float car_speed <- rnd(50.0, 60.0);     // ICE car top speed, sampled uniformly between 50–60 km/h
	float ele_car_speed <- rnd(40.0, 50.0); // EV top speed, sampled uniformly between 40–50 km/h

	// --- Day-cycle offsets ---
	float day_hour <- (day_counter - 1) * 24.0 update: (day_counter - 1) * 24.0;
	// Converts the current day number into an absolute hour offset so that
	// day 1 starts at hour 0, day 2 at hour 24, day 3 at hour 48, etc.
	// All schedule thresholds are expressed as `X + day_hour` to stay relative to the current day.

	// --- Battery consumption per step ---
	float bat_cons_max <- 0.15; // Maximum SoC (State of Charge) lost per step while driving (15% per minute at worst)
	float bat_cons_min <- 0.1;  // Minimum SoC lost per step while driving (10% per minute at best)

	// --- Half-day flag (controls which rush window is "active") ---
	bool half <- true; // true = morning rush window is eligible; toggled to false after morning rush ends

	// --- Convenience-factor weighting coefficients ---
	// The convenience_factor of a station is a weighted penalty score:
	//   convenience_factor = charging_coef * total_charging_time
	//                      + waiting_coef  * total_waiting_time
	//                      + distance_coef * total_distance_travel
	float charging_coef <- 1.5; // Weight for total charging time (high: penalises slow chargers more)
	float waiting_coef  <- 0.5; // Weight for total waiting time in queue
	float distance_coef <- 0.5; // Weight for distance travelled to reach the station

	int traveled_customer <- 0; // Running count of EVs that have reached a charging station (used to average distances)

	// --- Charging rate options (kW) — ordered fastest to slowest ---
	list<int> CHARGING_RATES <- [250, 180, 150, 60, 30, 11];
	// Used by find_available_port() to prefer higher-power ports first

	// --- Activity probability profile for EVs (determines how idle time is spent) ---
	float proba_home          <- 0.6;        // 60% chance an EV stays home when not committed to a task
	float proba_entertainment <- 0.4 * 0.2; // 8%  chance of going for leisure (40% not-home × 20% entertainment)
	float proba_eat           <- 0.4 * 0.3; // 12% chance of going to eat out
	float proba_work          <- 0.4 * 0.5; // 20% chance of driving to a work-type building

	// --- Building type lists (populated during init in main.gaml) ---
	list<building> buildings_type_1; // Residential buildings (type 1) — spawn/home locations for vehicles
	list<building> buildings_type_2; // Workplace buildings (type 2) — destinations for work commuters
	list<building> buildings_type_3; // Commercial/food/entertainment buildings (type 3) — leisure destinations
}


// ============================================================
// SPECIES: intersection
// Represents a road junction node in the network graph.
// Agents of this species are created programmatically from the
// graph vertices of the road shapefile, not from a shapefile directly.
// schedules: [] means GAMA will NOT call reflexes on these agents
// every step (they are purely spatial anchors, not active).
// ============================================================
species intersection schedules: [] skills: [intersection_skill] {
	// intersection_skill gives this species the attributes expected
	// by the driving skill (e.g. roads_out, linked_intersection).

	aspect base {
		draw circle(10) color: #green; // Renders as a small green dot for debug visualisation
	}
	// Commented-out line below was an earlier attempt to auto-assign
	// closest_intersection on the species itself — moved to building/charging_station init:
	// intersection closest_intersection <- intersection closest_to self;
}


// ============================================================
// SPECIES: charging_station
// Represents an EV charging facility (parking lots / dedicated stations).
// Tracks per-port availability, queuing, waiting/charging time statistics,
// power consumption, and a composite convenience factor.
// ============================================================
species charging_station {
	intersection closest_intersection <- intersection closest_to self;
	// The nearest road intersection — vehicles navigate HERE rather than
	// to the station's exact geometry (which may sit off-road).

	list<chargerbot> charging_vehicles; // Chargerbots currently occupying a station port and recharging
	list<chargerbot> waiting_queue;     // Chargerbots waiting for a station port; served FIFO
	int served_customer <- 0;       // Total chargerbots that have completed a full recharge session here
	float total_waiting_time <- 0.0;  // Cumulative waiting time (hours) across all vehicles
	float total_charging_time <- 0.0; // Cumulative charging time (hours) across all vehicles
	float total_distance_travel <- 0.0; // Sum of distances (m) driven by EVs to reach this station
	list<float> travel_periods <- [];   // Per-vehicle travel distances; summed into total_distance_travel
	float convenience_factor <- 0.0;    // Composite inconvenience score (lower = better); updated every step
	float power_consumed <- 0.0;        // Cumulative energy delivered (kWh)

	// Port counts by power level — decremented when occupied, incremented when released:
	int port_250 <- 0; // Number of 250 kW DC fast-charge ports available
	int port_180 <- 0; // Number of 180 kW DC fast-charge ports available
	int port_150 <- 0; // Number of 150 kW DC fast-charge ports available
	int port_60  <- 0; // Number of 60 kW AC fast-charge ports available
	int port_30  <- 0; // Number of 30 kW AC standard-charge ports available
	int port_11  <- 0; // Number of 11 kW AC slow-charge ports available (e.g. home-equivalent)

	string name;    // Identifier used in charts and CSV exports (read from shapefile attribute "temp_name")
	string Address; // Human-readable address (read from shapefile attribute "Name")

	int vehicle_waited   <- 0; // Total chargerbots that ever entered the waiting queue at this station
	int vehicle_charged  <- 0; // Total chargerbots that started an active charge session here


	aspect base {
		draw circle(40) color: #purple; // Large purple circle for easy identification in the 3D display
	}

	// --- Port management ---

	int find_available_port {
		// Returns the highest available charging rate (kW) with at least one free port,
		// or 0 if all ports are occupied. Iterates CHARGING_RATES in descending order
		// so faster chargers are always preferred.
		map<int, int> port_map <- [
			250::port_250,
			180::port_180,
			150::port_150,
			60::port_60,
			30::port_30,
			11::port_11
		]; // Convenience lookup: rate → current free count

		loop rate over: CHARGING_RATES {
			if (port_map[rate] > 0) {
				return rate; // First match wins (list is sorted fastest-first)
			}
		}
		return 0; // No ports free at any power level
	}

	action occupy_port(int rate) {
		// Decrements the count for the given port type by 1 when an EV starts charging.
		// Called by start_charging in the elecar species.
		switch rate {
			match 250 { port_250 <- port_250 - 1; }
			match 180 { port_180 <- port_180 - 1; }
			match 150 { port_150 <- port_150 - 1; }
			match 60  { port_60  <- port_60  - 1; }
			match 30  { port_30  <- port_30  - 1; }
			match 11  { port_11  <- port_11  - 1; }
		}
	}

	action release_port(int rate) {
		// Increments the count for the given port type by 1 when an EV finishes charging.
		// Called by stop_charging in the elecar species.
		switch rate {
			match 250 { port_250 <- port_250 + 1; }
			match 180 { port_180 <- port_180 + 1; }
			match 150 { port_150 <- port_150 + 1; }
			match 60  { port_60  <- port_60  + 1; }
			match 30  { port_30  <- port_30  + 1; }
			match 11  { port_11  <- port_11  + 1; }
		}
	}

	action add_to_queue (chargerbot ev) {
		// Appends an EV to the tail of the FIFO waiting queue.
		// Called when an EV arrives but find_available_port() returns 0.
		waiting_queue << ev;
	}

	action process_queue {
		// The queue now contains chargerbots waiting for a station port.
		// They simply retry the recharge allocation on their next step.
		if (!empty(waiting_queue)) {
			chargerbot next_vehicle <- waiting_queue[0];
			remove next_vehicle from: waiting_queue;
			ask next_vehicle {
				bot_state <- "recharge_wait";
			}
		}
	}

	// --- Statistics accessors ---

	float get_average_waiting_time {
		// Returns mean waiting time per vehicle (hours), or 0 if no vehicle has ever waited.
		return vehicle_waited > 0 ? total_waiting_time / vehicle_waited : 0.0;
	}

	float get_average_charging_time {
		// Returns mean charging session duration per vehicle (hours), or 0 if none have charged.
		return vehicle_charged > 0 ? total_charging_time / vehicle_charged : 0.0;
	}

	float get_total_distance {
		// Recomputes total_distance_travel from the travel_periods list, then returns
		// the average distance per served customer (meters), or 0 if none have been served.
		total_distance_travel <- sum(travel_periods);
		return traveled_customer > 0 ? total_distance_travel / traveled_customer : 0.0;
	}

	// --- Per-step reflexes ---

	reflex update_factor {
		// Recomputes the composite inconvenience score every step.
		// Higher values indicate a less convenient station from the user's perspective.
		convenience_factor <- (charging_coef * total_charging_time)
		                    + (waiting_coef  * total_waiting_time)
		                    + (distance_coef * total_distance_travel);
	}

	reflex update_waiting_time {
		// Every step, if there are vehicles in the queue:
		// 1. Adds a batch increment to total_waiting_time proportional to queue length.
		// 2. Increments each waiting vehicle's individual waiting_time counter.
		if (!empty(waiting_queue)) {
			float current_waiting_time <- length(waiting_queue) * step / 60;
			// length × step/60 converts to hours: e.g. 3 vehicles × 1 min/step ÷ 60 = 0.05 h
			total_waiting_time <- total_waiting_time + current_waiting_time;

			ask waiting_queue {
				waiting_time <- waiting_time + step; // Each queued vehicle accrues raw minute-steps of wait
			}
		}
	}

	reflex update_power_consumption {
		// Accumulates energy delivered each step: each actively charging vehicle
		// draws electrical_consumption kWh per step (≈ 11 kWh/h × 1 min/step / 60).
		if (!empty(charging_vehicles)) {
			float current_charging_time <- length(charging_vehicles) * electrical_consumption;
			power_consumed <- power_consumed + current_charging_time;
		}
	}

	reflex update_charging_time {
		// Accumulates total charging time in hours, and also increments
		// each active vehicle's own charging_time counter (in raw steps).
		if (!empty(charging_vehicles)) {
			float current_charging_time <- length(charging_vehicles) * step / 60;
			total_charging_time <- total_charging_time + current_charging_time;

			ask charging_vehicles {
				charging_time <- charging_time + step;
			}
		}
	}

	bool check_in_queue (chargerbot ev) {
		// Returns true if the given vehicle is already in the waiting queue.
		// Used by start_charging to avoid duplicate queue insertions.
		return ev in waiting_queue;
	}
}


// ============================================================
// SPECIES: road
// Represents a directed road segment loaded from a shapefile.
// Uses GAMA's road_skill which integrates with the driving skill.
// Each road is created TWICE in main.gaml (original + reversed)
// to model bidirectional traffic with separate directed edges.
// ============================================================
species road skills: [road_skill] {
	string type;        // Road category tag (e.g. "highway", "local") — loaded from shapefile attribute
	bool chargeroad;    // true if this road segment belongs to the charging-station access network;
	                    // these segments are given unlimited capacity and many lanes so EVs heading
	                    // to a station are never blocked by congestion

	int num_lanes <- 4;   // Default number of lanes; overridden in main.gaml init based on building proximity
	float capacity;       // Maximum number of vehicles that fit on this segment: 1 + (num_lanes × length / 3)

	int nb_vehicles -> length(all_agents);
	// Derived attribute: counts all vehicles currently on this road segment.
	// The `->` operator makes this a reactive/computed field, not a stored value.

	float speed_coeff <- 1.0 min: 0.1 update: 1.0 - (nb_vehicles / capacity);
	// Speed coefficient used by the driving skill to slow vehicles as congestion builds.
	// Formula: 1 - (occupancy / capacity), clamped to a minimum of 0.1
	// so vehicles always move at least 10% of their max speed.

	init {
		if (!chargeroad) {
			capacity <- 1 + (num_lanes * shape.perimeter / 3);
			// For normal roads: capacity scales with the number of lanes and road length.
			// Divided by 3 because a typical vehicle + gap occupies ~3 m.
			// chargeroad segments skip this (their capacity is set to 10000 in main.gaml).
		}
	}
}


// ============================================================
// SPECIES: vehicle  (abstract base for all moving agents)
// Provides shared state, scheduling logic, movement, and
// daily routine reflexes for both ICE cars and EVs.
// Uses GAMA's `driving` skill for lane-based road navigation.
// ============================================================
species vehicle skills: [driving] {
	string type;            // Vehicle category string (informational)
	building target;        // Current navigation destination building
	building work_place <- one_of(buildings_type_2); // Randomly assigned workplace from type-2 buildings
	point shift_pt <- location; // Lateral display offset (so lanes don't visually overlap)
	bool at_home <- true;       // Whether the vehicle is currently at its home location
	building temp_target <- nil; // Temporary destination override (e.g. lunch detour); original target restored after

	bool is_ev <- false;          // true for EV subclasses (elecar and children)
	float day_start <- rnd(5.0 + day_hour, 7.0 + day_hour); // Random daily start time: 05:00–07:00 on current day
	float day_end   <- rnd(20.0 + day_hour, 24.0 + day_hour); // Random daily end time: 20:00–24:00
	float taxi_end  <- rnd(20.0 + day_hour, 24.0 + day_hour); // Separate end time used specifically by taxi variants

	building home <- nil;        // Home building; set in init to the building at the spawn location
	bool day_end_time   <- true; // true when simulation_hour has passed day_end (triggers return-home behaviour)
	bool day_start_time <- false;// true when simulation_hour is between day_start and day_end

	bool needs_charging <- false; // EV flag: battery is below threshold, vehicle must find a charger
	bool is_charging    <- false; // EV flag: vehicle is currently at a port and charging

	bool is_work_car          <- false; // Assigned behaviour type: commuter (work → home daily routine)
	bool is_entertainment_car <- false; // Assigned behaviour type: leisure traveller (random trips)

	bool has_lunch    <- false; // Guards the lunch-break detour so it only triggers once per day
	bool has_gone_out <- false; // Guards the evening outing so it only triggers once per day

	float wait_until <- -1.0; // Simulation hour at which a vehicle should resume movement after a dwell stop.
	                           // -1.0 means "not waiting".
	bool wait <- false;       // Legacy wait flag (mostly superseded by wait_until check)

	// Entertainment time windows (randomised so not all leisure vehicles move simultaneously):
	float entertain_time1 <- rnd(8.0, 11.0);  // Morning leisure window start (08:00–11:00)
	float entertain_time2 <- rnd(13.0, 17.0); // Afternoon leisure window start (13:00–17:00)
	float entertain_time3 <- rnd(18.0, 22.0); // Evening leisure window start (18:00–22:00)
	bool eating <- false; // Guards the lunch-eating state to prevent re-triggering

	image_file my_icon; // Icon image shown in the 3D display (overridden by each subclass)
	float size <- 10.0; // Icon rendering scale factor

	init {
		proba_respect_priorities <- 0.0;  // Vehicles ignore intersection priorities (no stop-sign logic)
		proba_respect_stops      <- [1.0]; // Vehicles always obey stop signals (traffic lights/forced stops)
		proba_use_linked_road    <- 0.0;  // Vehicles do NOT use linked (opposite-direction) roads for overtaking
		lane_change_limit        <- 2;    // Maximum lane changes per step
		linked_lane_limit        <- 0;    // No lane incursions into oncoming traffic
		if (home = nil) {
			home <- building(location);
			// Converts the spawn location point to the building at that point;
			// used as the vehicle's permanent home for end-of-day returns.
		}
	}

	// --- Work commuter daily routine ---
	reflex work_vehicle_behavior when: is_work_car {

		// Morning commute: triggered once when day has started and no destination is set
		if (day_start_time and target = nil and !needs_charging) {
			target <- work_place; // Drive to the pre-assigned workplace
			do compute_path graph: road_network target: target.closest_intersection;
			// compute_path uses FloydWarshall shortest path on road_network
			wait <- true;   // Signal that vehicle will park/wait at destination
			at_home <- false;
		}

		// Lunch break (12:00–13:00): 50% chance of a food detour
		if (simulation_hour >= day_hour + 12 and simulation_hour < day_hour + 13
		    and has_lunch = false and !needs_charging) {
			if (flip(0.5)) {
				temp_target <- target; // Save current target so we can return after lunch
				target <- one_of(buildings_type_3 closest_to self); // Nearest restaurant/café
				has_lunch <- true;
				wait <- false;
				do compute_path graph: road_network target: target.closest_intersection;
			} else {
				has_lunch <- true; // Skip the detour but mark lunch as done
			}
		}

		// Return from lunch: once the lunch detour destination is reached (final_target = nil)
		// and there is a saved temp_target, resume the original route
		if (has_lunch and final_target = nil and temp_target != nil and !needs_charging) {
			target <- temp_target;
			temp_target <- nil;
			do compute_path graph: road_network target: target.closest_intersection;
		}

		// Resume after a timed dwell (e.g. post-lunch wait): once wait_until is exceeded,
		// go home for the rest of the day
		if (wait_until >= 0 and simulation_hour >= wait_until and !needs_charging) {
			has_lunch <- false;
			target <- home;
			at_home <- true;
			wait_until <- -1.0;
			do compute_path graph: road_network target: target.closest_intersection;
		}

		// End of day: pick either eating out or going straight home (50/50)
		if (day_end_time and final_target = nil and not at_home and !needs_charging) {
			if (flip(0.5)) {
				target <- one_of(buildings_type_3); // Dinner stop
				wait_until <- simulation_hour + rnd(0.5, 1); // Dwell 30–60 min
			} else {
				target <- home;
				at_home <- true;
				has_lunch <- false;
			}
			do compute_path graph: road_network target: target.closest_intersection;
		}

		// Near midnight (23:30 of current day): clear target so next day can start fresh
		if (simulation_hour > day_hour + 23.5) {
			target <- nil;
		}
	}

	// --- Leisure vehicle daily routine ---
	reflex entertainment_behavior when: is_entertainment_car {

		// Trigger an outing during one of three daily time windows (or at lunch),
		// provided the vehicle is idle (final_target = nil) and its dwell timer has expired
		if (final_target = nil and wait_until < simulation_hour and !needs_charging) {

			if ((simulation_hour >= entertain_time1 and simulation_hour <= entertain_time1 + step/60) or
			    (simulation_hour >= entertain_time2 and simulation_hour < 17.0 and not eating) or
			    (simulation_hour >= entertain_time3 and simulation_hour <= entertain_time3 + step/60)) {

				if (flip(0.5)) {
					target <- one_of(buildings_type_3); // Random leisure/commercial building
					do compute_path graph: road_network target: target.closest_intersection;
					wait_until <- simulation_hour + rnd(1, 3); // Stay 1–3 hours before returning
				}

			// Lunchtime eating logic (12:00–13:00)
			} else if (simulation_hour >= day_hour + 12 and simulation_hour < day_hour + 13) {
				if (flip(0.5)) {
					target <- one_of(buildings_type_3 closest_to self);
					do compute_path graph: road_network target: target.closest_intersection;
					wait_until <- simulation_hour + rnd(0.5, 1.5);
					eating <- true;
				}
			}
		}

		// Reset eating flag after 13:00 (lunch window has closed)
		if (simulation_hour > day_hour + 13) {
			eating <- false;
		}

		// After a dwell, return home
		if (wait_until >= 0 and simulation_hour >= wait_until and final_target = nil and !needs_charging) {
			target <- home;
			do compute_path graph: road_network target: home.closest_intersection;
			wait_until <- -1.0;
		}
	}

	// --- Schedule management ---
	reflex update_schedule {
		// Flips day_start_time / day_end_time based on simulation_hour crossing the
		// vehicle's personal day_start and day_end thresholds.
		if (simulation_hour > day_start and day_start_time = false) {
			day_start_time <- true;
			day_end_time   <- false;
		}
		if (simulation_hour > day_end and day_end_time = false) {
			day_end_time   <- true;
			day_start_time <- false;
		}
	}

	// --- Movement ---
	reflex move when: final_target != nil {
		// Called every step while the vehicle has an active path to follow.
		do drive; // Advances the vehicle along the computed path (driving skill built-in)
		if (final_target = nil) {
			do unregister; // Vehicle reached its destination; remove it from road occupancy tracking
		} else {
			shift_pt <- compute_position(); // Recompute lateral display position for current lane
		}
	}

	// --- Lane-offset calculation for 2D/3D display ---
	point compute_position {
		// Returns a point offset laterally from the road centre line
		// to represent the vehicle's actual lane position visually.
		if (current_road != nil) {
			float dist <- (road(current_road).num_lanes
			               - lowest_lane
			               - mean(range(num_lanes_occupied - 1))
			               - 0.5) * lane_width;
			// Explanation:
			//   road.num_lanes - lowest_lane          = lanes to the right of the vehicle
			//   - mean(range(num_lanes_occupied - 1)) = centres multi-lane vehicles
			//   - 0.5                                 = half-lane centering offset
			//   × lane_width                          = converts to metres

			if violating_oneway {
				dist <- -dist; // Mirror to the left side when driving against traffic
			}
			return location + {cos(heading + 90) * dist / 10, sin(heading + 90) * dist / 10};
			// Projects the lateral offset in the perpendicular direction to the current heading.
			// Divided by 10 to scale the geometric space.
		} else {
			return {0, 0}; // Not on a road yet; no offset
		}
	}
}


// ============================================================
// SPECIES: car   (ICE vehicle, child of vehicle)
// Regular petrol/diesel car with no battery management.
// ============================================================
species car parent: vehicle {
	float vehicle_length <- rnd(4.0, 5.0) #m; // Random vehicle length 4–5 m (affects safe following distance)
	int num_lanes_occupied <- 1;               // Occupies exactly one lane
	float max_speed <- car_speed #km / #h;     // Uses the global ICE speed range

	image_file my_icon <- image_file("../includes/car.png"); // Car icon for 3D display
	
	aspect icon {
		draw my_icon size: 2 * size;
	}
}


// ============================================================
// SPECIES: rush_hour_car   (temporary extra ICE car, child of car)
// Created in bulk at rush-hour onset by main.gaml's
// update_rush_car_population action; destroyed after rush ends.
// Overrides behavioural reflexes to use a simple point-to-point
// random path instead of the full daily routine.
// ============================================================
species rush_hour_car parent: car {
	float vehicle_length <- rnd(4.0, 5.0) #m;
	int num_lanes_occupied <- 1;
	float max_speed <- car_speed #km / #h;
	image_file my_icon <- image_file("../includes/car.png");
	
	aspect icon {
		draw my_icon size: 2 * size;
	}

	reflex choose_path when: final_target = nil and !needs_charging and day_start_time {
		// Continuously pick a new random destination while the day is active
		do select_target_path;
	}

	// Override parent reflexes with empty bodies so the full daily schedule
	// (work/entertainment) does NOT run for rush-hour cars:
	reflex entertainment_behavior when: is_entertainment_car {}
	reflex work_vehicle_behavior  when: is_work_car          {}

	action select_target_path {
		// Chooses either a random building or returns to temp_target if one was saved.
		if temp_target = nil {
			target <- one_of(building); // Random building anywhere in the map
		} else {
			target <- temp_target;
			temp_target <- nil;
		}
		write target.location;             // Debug: log destination coordinate
		write target.closest_intersection; // Debug: log target intersection
		location <- (intersection closest_to self).location; // Snap to nearest intersection before pathing
		do compute_path graph: road_network target: target.closest_intersection;
	}

	reflex go_home when: (day_end_time) {
		// When day_end_time flips true, override current target and head home
		target <- home;
		do compute_path graph: road_network target: target.closest_intersection;
	}
}


// ============================================================
// SPECIES: rush_hour_private   (temporary EV private car, child of taxi_ev)
// Rush-hour counterpart of rush_hour_car but for private EVs.
// Inherits taxi_ev's battery management; uses the random-destination
// routing pattern of rush_hour_car.
// ============================================================
species rush_hour_private parent: private_ev {
	float vehicle_length <- rnd(4.0, 5.0) #m;
	int num_lanes_occupied <- 1;
	float max_speed <- ele_car_speed #km / #h;
	float battery_level <- float(35, 40); // Spawned with a lower initial charge (35–40%) to model mid-day battery state
	image_file my_icon <- image_file("../includes/vinfast.png"); // VinFast EV icon
	
	aspect icon {
		draw my_icon size: 2 * size;
	}

	reflex choose_path when: final_target = nil and !needs_charging and !is_parked and !chargerbot_requested and day_start_time {
		do select_target_path;
	}

	reflex entertainment_behavior when: is_entertainment_car {}
	reflex work_vehicle_behavior  when: is_work_car          {}

	action select_target_path {
		if temp_target = nil {
			target <- one_of(building);
		} else {
			target <- temp_target;
			temp_target <- nil;
		}
		write target.location;
		write target.closest_intersection;
		location <- (intersection closest_to self).location;
		do compute_path graph: road_network target: target.closest_intersection;
	}

	reflex go_home when: (day_end_time) {
		target <- home;
		do compute_path graph: road_network target: target.closest_intersection;
	}
}


// ============================================================
// SPECIES: rush_hour_taxi   (temporary EV taxi, child of taxi_ev)
// Same as rush_hour_private but uses the taxi icon.
// ============================================================
species rush_hour_taxi parent: taxi_ev {
	float vehicle_length <- rnd(4.0, 5.0) #m;
	int num_lanes_occupied <- 1;
	float max_speed <- ele_car_speed #km / #h;
	float battery_level <- float(35, 40); // Lower starting charge to match rush-hour mid-shift scenario

	image_file my_icon <- image_file("../includes/xanhsm.png"); // Xanh SM taxi icon
	
	aspect icon {
		draw my_icon size: 2 * size;
	}

	reflex choose_path when: final_target = nil and !needs_charging and !is_parked and !chargerbot_requested and day_start_time {
		do select_target_path;
	}

	reflex entertainment_behavior when: is_entertainment_car {}
	reflex work_vehicle_behavior  when: is_work_car          {}

	action select_target_path {
		if temp_target = nil {
			target <- one_of(building);
		} else {
			target <- temp_target;
			temp_target <- nil;
		}
		write target.location;
		write target.closest_intersection;
		location <- (intersection closest_to self).location;
		do compute_path graph: road_network target: target.closest_intersection;
	}

	reflex go_home when: (day_end_time) {
		target <- home;
		do compute_path graph: road_network target: target.closest_intersection;
	}
}

// --- Commented-out species (retained for reference) ---
// entertainment_car and work_car were earlier attempts to split
// EV behaviour by role into distinct species. This was refactored
// into boolean flags (is_entertainment_car / is_work_car) on vehicle
// so a single agent can switch roles without species conversion.

// ============================================================
// SPECIES: chargerbot   (mobile charging robot / Edge server)
// Robot sạc di động: được elecar gọi khi cần sạc (chọn theo
// khoảng cách gần nhất), tự lái tới xe, truyền năng lượng từ
// pin của chính nó sang xe. Sau mỗi lượt phục vụ, nó hỏi Edge
// server (Python, qua socket TCP) xem còn đủ pin nhận job tiếp
// hay phải quay về charging_station gần nhất để tự sạc lại.
//
// State machine (bot_state):
//   idle        -> đang rảnh, chờ được gọi
//   dispatched  -> đang lái tới chỗ elecar
//   serving     -> đang truyền năng lượng cho elecar
//   returning   -> đang lái về charging_station để tự sạc
//   recharging  -> đang tự sạc tại charging_station
// ============================================================
species chargerbot parent: vehicle skills: [network, driving] {

	// --- Kết nối Edge (Python) ---
	string edge_host <- "localhost";
	int    edge_port <- 3001;
	map<string, bool> pending_requests <- []; // request_id -> true, chỉ để biết đang chờ phản hồi nào

	// --- Pin của chính chargerbot ---
	float battery_level    <- 100.0; // % pin hiện tại
	float discharge_rate   <- 5.0;   // % pin bot mất mỗi step khi đang sạc cho xe
	float own_charge_rate  <- 20.0;  // % pin bot hồi phục mỗi step khi tự sạc tại station
	float charging_time    <- 0.0;   // station-recharge duration in simulation steps
	float max_speed <- ele_car_speed #km / #h;

	// --- Trạng thái & tác vụ hiện tại ---
	string bot_state <- "idle"; // idle | dispatched | serving | returning | recharging
	elecar client <- nil;
	charging_station home_station <- nil;

	init {
		do connect to: edge_host protocol: "tcp_client" port: edge_port raw: true
		     with_name: "Edge_" + int(self);
	}

	// ------------------------------------------------------------
	// Dispatch a mobile charging service to an EV parked at its current
	// destination. The bot itself is the CMEI Edge client.
	// ------------------------------------------------------------
	bool dispatch_to (elecar ev) {
		if (bot_state != "idle") { return false; }
		client    <- ev;
		bot_state <- "dispatched";

		// Keep the EV stationary while the bot is travelling to it.
		ask ev {
			is_charging <- true;
			chargerbot_requested <- true;
		}

		// Inform the Edge policy about this dispatch. The current GAMA-side
		// allocator chooses the nearest idle bot; Edge learns from the request
		// features and Cloud aggregates the resulting local weights.
		string rid <- "chg_" + string(int(self)) + "_" + string(cycle);
		map<string, unknown> req <- [
			"type"::"charge_request",
			"request_id"::rid,
			"bot_id"::string(int(self)),
			"vehicle_id"::string(int(ev)),
			"vehicle_type"::(ev is taxi_ev ? "taxi_ev" : "private_ev"),
			"vehicle_battery"::ev.battery_level,
			"bot_battery"::battery_level,
			"target_soc"::ev.charge_target_soc,
			"distance"::(distance_to ev),
			"is_parked"::ev.is_parked
		];
		do send to: "server" contents: to_json(req);

		do compute_path graph: road_network target: (intersection closest_to ev);
		return true;
	}

	reflex move_to_client when: bot_state = "dispatched" and final_target != nil {
		do drive;
	}

	reflex arrive_at_client when: bot_state = "dispatched" and final_target = nil {
		bot_state <- "serving";
	}

	// Deliver energy until the vehicle's requested SoC is reached or the
	// chargerbot itself needs to stop. For a private EV, the target is the
	// requested customer SoC (100% by default); for taxis it is normally 70%.
	reflex serve_client when: bot_state = "serving" {
		if (client = nil) {
			do finish_service(false);
			return;
		}

		float remaining <- max(client.charge_target_soc - client.battery_level, 0.0);
		if (remaining <= 0.0) {
			do finish_service(true);
			return;
		}

		float transfer <- min(discharge_rate, min(battery_level, remaining));
		ask client {
			battery_level <- min(100.0, battery_level + transfer);
		}
		battery_level <- battery_level - transfer;

		if (client.battery_level >= client.charge_target_soc) {
			do finish_service(true);
		} else if (battery_level <= 0.0) {
			do finish_service(false);
		}
	}

	// `completed = true` means the requested SoC was reached. `false` means
	// the bot had to stop early; the EV remains parked and can request another bot.
	action finish_service (bool completed) {
		if (client != nil) {
			ask client {
				is_charging <- false;
				chargerbot_requested <- false;
				needs_charging <- !completed;
			}
		}
		client    <- nil;
		bot_state <- "idle";
		do request_battery_check;
	}

	action request_battery_check {
		string rid <- "bat_" + string(int(self)) + "_" + string(cycle);
		charging_station nearest <- all_stations with_min_of (each distance_to self);
		float dist_to_nearest <- (nearest != nil) ? (nearest distance_to self) : 99999.0;

		map<string, unknown> req <- [
			"type"::"battery_check",
			"request_id"::rid,
			"bot_id"::string(int(self)),
			"battery_level"::battery_level,
			"nearest_station_distance"::dist_to_nearest
		];
		do send to: "server" contents: to_json(req);
		pending_requests[rid] <- true;
	}

	reflex fetch_edge_response when: has_more_message() {
		message mess <- fetch_message();
		map parsed <- map(from_json(mess.contents));
		if (parsed["type"] = "charge_response") { return; }
		string rid <- string(parsed["request_id"]);
		if !(rid in pending_requests.keys) { return; }
		remove key: rid from: pending_requests;

		if (parsed["type"] = "battery_decision") {
			string decision <- string(parsed["action"]);
			if (decision = "return_to_base") {
				home_station <- all_stations with_min_of (each distance_to self);
				if (home_station != nil) {
					bot_state <- "returning";
					do compute_path graph: road_network target: home_station.closest_intersection;
				}
			}
		}
	}

	reflex move_to_station when: bot_state = "returning" and final_target != nil {
		do drive;
	}

	reflex arrive_at_station when: bot_state = "returning" and final_target = nil {
		if (home_station != nil) {
			int port_rate <- home_station.find_available_port();
			if (port_rate > 0) {
				charge_rate <- port_rate;
				charging_time <- 0.0;
				ask home_station {
					do occupy_port(port_rate);
					charging_vehicles << myself;
					vehicle_charged <- vehicle_charged + 1;
				}
				bot_state <- "recharging";
			} else {
				bot_state <- "recharge_wait";
			}
		} else {
			bot_state <- "idle";
		}
	}

	reflex retry_station_recharge when: bot_state = "recharge_wait" and home_station != nil {
		int port_rate <- home_station.find_available_port();
		if (port_rate > 0) {
			charge_rate <- port_rate;
			ask home_station {
				do occupy_port(port_rate);
				charging_vehicles << myself;
				vehicle_charged <- vehicle_charged + 1;
			}
			bot_state <- "recharging";
		}
	}

	reflex self_recharge when: bot_state = "recharging" {
		battery_level <- min(100.0, battery_level + own_charge_rate);
		if (battery_level >= 100.0) {
			if (home_station != nil) {
				ask home_station {
					do release_port(myself.charge_rate);
					remove myself from: charging_vehicles;
					served_customer <- served_customer + 1;
				}
			}
			charge_rate <- 0;
			bot_state <- "idle";
			home_station <- nil;
		}
	}

	aspect icon {
		draw circle(3) color: #orange border: #black;
	}
}


// ============================================================
// SPECIES: elecar   (abstract EV base, child of vehicle)
// Adds battery state, charging station awareness, port interaction,
// home charging, and distance-to-station tracking on top of vehicle.
// ============================================================
species elecar parent: vehicle {
	float vehicle_length <- float(rnd(4.0, 5.0)) #m;
	int num_lanes_occupied <- 1;
	float max_speed <- ele_car_speed #km / #h;

	charging_station current_station <- nil; // Legacy field: only chargerbots use stations for self-recharge
	list<charging_station> all_stations;     // Reference to the global station list (kept for chargerbot compatibility)
	point target_station;                    // Legacy point-based station target (unused by EV charging)
	float battery_level <- float(rnd(40, 100)); // Initial SoC: random 40–100%
	int charge_rate <- 0;                    // Legacy station charge rate; EVs are charged by chargerbots now
	float waiting_time <- 0.0;               // Legacy queue waiting counter
	float charging_time <- 0.0;              // Mobile charging service duration in steps
	float total_distance <- 0.0;             // Legacy station-approach distance metric
	point new;                               // Previous waypoint, kept for compatibility
	bool charge_home <- false;               // Legacy flag; direct home charging is disabled
	float max_waiting_time <- 30.0;          // Legacy threshold

	// --- Mobile charging service state ---
	bool chargerbot_requested <- false;      // true while a chargerbot is assigned / on the way
	float charge_target_soc <- 100.0;        // SoC requested by the current charging service
	bool is_parked <- false;                 // Vehicle is stationary at its current destination

    // ----------------------------------------------------------
    // Multi-level parking / twin-tower attributes
    // ----------------------------------------------------------
    tower_building home_tower   <- nil; // The tower whose parking this EV prefers (set at creation)
    parking_lot    parked_in    <- nil; // The actual lot this EV is currently parked in (nil = not parked)
    int            parked_level <- -1;  // Level within parked_in (-1 = not parked)
    bool           wants_to_park <- false; // true when the EV has decided to seek a parking space


    // ----------------------------------------------------------
    // Action: park at the current destination. The vehicle stays where
    // the customer/passenger was dropped off; charging is performed by
    // a mobile chargerbot, not by a fixed EV charging port.
    // ----------------------------------------------------------
    action park_at_destination {
        is_parked <- true;
        wants_to_park <- false;
        parked_in <- nil;
        parked_level <- -1;
    }

    // Arrival at a destination creates the parking/drop-off state.
    // Private EVs request charging when their SoC is below the configurable
    // customer-request threshold. Taxis perform their own battery check.
    reflex arrive_and_park when: final_target = nil and target != nil and !is_parked and day_start_time {
        do park_at_destination;
        if (self is private_ev) and battery_level < private_charge_request_threshold and !chargerbot_requested {
            needs_charging <- true;
            charge_target_soc <- private_charge_target_soc;
            do request_charging_service;
        }
    }

    // A parked EV may leave only when its higher-level behaviour has chosen
    // a new target and no charging service is active.
    reflex depart_destination when: is_parked and final_target != nil and !is_charging and !needs_charging and !chargerbot_requested {
        is_parked <- false;
    }

    // ----------------------------------------------------------
    // Action: find and enter the best available parking lot.
    // Priority: home tower's lot → twin tower's lot → nil (no park).
    // Navigates to the entry intersection of the chosen lot's level.
    // ----------------------------------------------------------
    action seek_parking {
        wants_to_park <- true;
        if (home_tower = nil) { return; }

        parking_lot chosen_lot <- home_tower.find_available_lot();
        if (chosen_lot = nil) {
            write "" + self + " no parking available in either tower"; // Debug
            wants_to_park <- false;
            return;
        }

        int chosen_level <- chosen_lot.find_available_level();
        if (chosen_level < 0) {
            write "" + self + " lot chosen but no level found"; // Shouldn't happen; guard anyway
            wants_to_park <- false;
            return;
        }

        // Navigate to the entry point of the chosen level
        intersection entry_pt;
        if (chosen_level < length(chosen_lot.level_entry_points)
                and chosen_lot.level_entry_points[chosen_level] != nil) {
            entry_pt <- chosen_lot.level_entry_points[chosen_level];
        } else {
            // Fallback: use the owning tower's entrance intersection
            if (chosen_lot.owner_tower != nil) {
                entry_pt <- chosen_lot.owner_tower.entrance_intersection;
            }
        }

        if (entry_pt != nil) {
            // Store the chosen lot so the arrival reflex can complete the transaction
            parked_in    <- chosen_lot;
            parked_level <- chosen_level;
            temp_target  <- target; // Save original destination
            do compute_path graph: road_network target: entry_pt;
        } else {
            write "" + self + " cannot find entry intersection for parking"; // Debug
            parked_in    <- nil;
            parked_level <- -1;
            wants_to_park <- false;
        }
    }

    // ----------------------------------------------------------
    // Reflex: complete parking when vehicle arrives at entry point
    // ----------------------------------------------------------
    reflex complete_parking when: wants_to_park and parked_in != nil and final_target = nil and !is_parked {
        bool success <- parked_in.enter_level(parked_level, self);
        if (success) {
            is_parked     <- true;
            wants_to_park <- false;
            // Parking only: no direct EV charging at the parking lot.
            // A chargerbot must be dispatched to the parked EV when charging is requested.
        } else {
            // Race condition: level filled between selection and arrival — retry
            parked_in    <- nil;
            parked_level <- -1;
            wants_to_park <- false;
            do seek_parking; // Re-attempt with updated occupancy
        }
    }

    // ----------------------------------------------------------
    // Action: leave the parking lot (called by end-of-dwell logic)
    // Navigates the EV to the exit intersection of the lot's tower.
    // ----------------------------------------------------------
    action leave_parking {
        if (!is_parked or parked_in = nil) { return; }

        // Release charging port if it was in use
        if (is_charging and charge_rate = 11) {
            ask parked_in { do release_ev_port(myself.parked_level); }
            is_charging  <- false;
            charge_rate  <- 0;
        }

        ask parked_in { do leave_level(myself.parked_level); }

        // Navigate to the tower's exit intersection
        intersection exit_pt <- nil;
        if (parked_level < length(parked_in.level_exit_points)
                and parked_in.level_exit_points[parked_level] != nil) {
            exit_pt <- parked_in.level_exit_points[parked_level];
        } else if (parked_in.owner_tower != nil) {
            exit_pt <- parked_in.owner_tower.exit_intersection;
        }

        is_parked    <- false;
        parked_in    <- nil;
        parked_level <- -1;

        if (exit_pt != nil) {
            // Restore original destination after exiting
            target <- temp_target != nil ? temp_target : home;
            temp_target <- nil;
            do compute_path graph: road_network target: exit_pt;
        }
    }

	// --- Battery depletion death ---
	reflex cease when: battery_level <= 0 and !is_charging and !chargerbot_requested {
		lost_car_location << self.location;
		batter_insufficient <- batter_insufficient + 1;
		do die;
	}

	// --- Mobile charging request ---
	action request_charging_service {
		if (!use_chargerbot_dispatch) {
			write "Legacy fixed-station charging is disabled by the new mobile-charging architecture.";
			return;
		}
		if (chargerbot_requested or is_charging) { return; }

		list<chargerbot> idle_bots <- chargerbot where (each.bot_state = "idle");
		if (!empty(idle_bots)) {
			chargerbot nearest_bot <- idle_bots with_min_of (each distance_to self);
			bool accepted <- nearest_bot.dispatch_to(self);
			if (accepted) {
				chargerbot_requested <- true;
				is_parked <- true;
				return;
			}
		}
		// No bot is available yet. Stay parked and retry on the next step.
		chargerbot_requested <- false;
	}

	// Retry mobile charging while parked if the vehicle still needs energy.
	reflex retry_charging_request when: is_parked and needs_charging and !is_charging and !chargerbot_requested and day_start_time {
		do request_charging_service;
	}

	// When charging is requested/active, the EV must remain at its destination.
	reflex move when: final_target != nil and battery_level > 0.0 {
		if (!is_charging and !is_parked and !chargerbot_requested) {
			do drive;
			if (battery_level < 30.0 and !chargerbot_requested) {
				needs_charging <- true;
				charge_target_soc <- (self is taxi_ev) ? taxi_charge_target_soc : private_charge_target_soc;
			}
			shift_pt <- compute_position();
		}
	}

	// Legacy fixed-station action is intentionally disabled for EVs.
	action select_charging_station {
		write "select_charging_station is disabled for EVs: chargerbots perform all mobile charging.";
	}

	action start_charging {
		// Kept as a compatibility stub for old callers.
		needs_charging <- true;
		if (charge_target_soc <= battery_level) { charge_target_soc <- private_charge_target_soc; }
		do request_charging_service;
	}

	// Direct home/public-port charging is removed from the EV model.
	reflex charge_at_home when: false {}
	reflex day_end_charge when: false {}

	// Mobile charging itself is performed by chargerbot; this reflex only
	// records the service as active while the bot is attached.
	reflex charging when: is_charging {
		charging_time <- charging_time + step;
	}

	action stop_charging {
		is_charging <- false;
		needs_charging <- false;
		chargerbot_requested <- false;
		charge_rate <- 0;
	}

	// Passive battery drain while the EV is actually driving.
	reflex consume_battery when: battery_level > 0.0 and !is_charging and !is_parked and !chargerbot_requested and day_start_time and final_target != nil {
		battery_level <- max(battery_level - rnd(bat_cons_min, bat_cons_max), 0);
	}

}


// ============================================================
// SPECIES: private_ev   (private EV car, child of elecar)
// A personally-owned electric vehicle. No additional behaviour
// beyond elecar — all routing logic comes from the work/entertainment
// flags set in main.gaml's init loop.
// ============================================================
species private_ev parent: elecar {
	image_file my_icon <- image_file("../includes/vinfast.png"); // VinFast icon
	
	aspect icon {
		draw my_icon size: 2 * size;
	}
}


// ============================================================
// SPECIES: taxi_ev   (EV taxi, child of elecar)
// An electric taxi that continuously picks random destinations
// while active. Unlike private_ev it overrides move logic with
// an explicit choose_path reflex so it never sits idle.
// ============================================================
species taxi_ev parent: elecar {
	image_file my_icon <- image_file("../includes/xanhsm.png");

	aspect icon {
		draw my_icon size: 2 * size;
	}

	// After every passenger drop-off, the taxi is considered parked at the
	// destination. It checks SoC before accepting another trip.
	reflex taxi_dropoff_battery_check when: is_parked and !is_charging and !chargerbot_requested and day_start_time {
		if (battery_level < taxi_charge_request_threshold) {
			needs_charging <- true;
			charge_target_soc <- taxi_charge_target_soc;
			do request_charging_service;
		} else {
			needs_charging <- false;
			is_parked <- false;
			do select_target_path;
		}
	}

	reflex taxi_resume_after_charge when: is_parked and !is_charging and !chargerbot_requested and !needs_charging and battery_level >= taxi_charge_target_soc and day_start_time {
		is_parked <- false;
		do select_target_path;
	}

	reflex choose_path when: final_target = nil and !needs_charging and !is_parked and !chargerbot_requested and day_start_time {
		do select_target_path;
	}

	reflex entertainment_behavior when: is_entertainment_car {}
	reflex work_vehicle_behavior  when: is_work_car          {}

	action select_target_path {
		if (day_end_time) { return; }
		if temp_target = nil {
			target <- one_of(building);
		} else {
			target <- temp_target;
			temp_target <- nil;
		}
		write target.location;
		write target.closest_intersection;
		location <- (intersection closest_to self).location;
		do compute_path graph: road_network target: target.closest_intersection;
	}

	reflex go_home when: day_end_time and !is_charging and !chargerbot_requested {
		target <- home;
		if (is_parked) { is_parked <- false; }
		if (target != nil) { do compute_path graph: road_network target: target.closest_intersection; }
	}
}



// ============================================================
// SPECIES: building   (static spatial anchor)
// Loaded from shapefiles in main.gaml.
// Categorised by build_type (1=residential, 2=workplace, 3=commercial).
// schedules: [] disables per-step execution for performance.
// ============================================================
species building schedules: [] {
	intersection closest_intersection <- intersection closest_to self.location;
	// Pre-computed nearest road intersection so vehicles can path to this building
	// without searching every step.

	string type;             // Raw type string from shapefile (informational)
	int pollution_index;     // Placeholder for future air-quality modelling
	rgb color_outer_building; // Display colour, set per build_type in main.gaml init
	int build_type;          // 1 = residential, 2 = workplace, 3 = commercial/food/leisure
}


// ============================================================
// SPECIES: parking_lot
// Represents a multi-level underground or above-ground parking
// facility attached to a tower_building.  Each level is treated
// as a separate layer of spaces; vehicles fill levels from the
// ground up and vacate from the top down (LIFO per level, FIFO
// across levels for simplicity).
//
// Key responsibilities
//   • Track per-level occupancy
//   • Expose entry and exit intersection points per level
//   • Charge EVs while parked (acts as a combined charging_station)
//   • Report occupancy to owner tower so overflow logic can fire
// ============================================================
species parking_lot {

    // ----------------------------------------------------------
    // Structural parameters
    // ----------------------------------------------------------
    int num_levels      <- 3;        // Total storeys (ground = level 0)
    int spaces_per_level <- 50;      // Parking bays per storey
    int total_capacity -> num_levels * spaces_per_level; // Derived total

    // Per-level occupancy counter list: index = level number (0-based)
    // Populated in init; length must equal num_levels.
    list<int> level_occupancy <- [];

    // Per-level entry and exit intersections.
    // Each list has `num_levels` elements.
    // Level 0 uses the ground-floor entrance/exit of the building;
    // upper levels may share the same ramp intersection or have
    // dedicated points in larger facilities.
    list<intersection> level_entry_points <- [];
    list<intersection> level_exit_points  <- [];

    // Reference back to the owning tower
    tower_building owner_tower <- nil;

    // ----------------------------------------------------------
    // Parking only: EVs do not charge directly in the parking lot.
    // Mobile chargerbots are dispatched to parked vehicles instead.
    // ----------------------------------------------------------
    list<int> level_ev_ports <- []; // Retained only for data compatibility; always zero.

    // Aggregate statistics (mirrors charging_station for CSV export)
    int    served_ev        <- 0;
    float  power_consumed   <- 0.0;
    string name             <- "ParkingLot";

    // ----------------------------------------------------------
    // Init: set up per-level data structures
    // ----------------------------------------------------------
    init {
        // Populate level_occupancy and level_ev_ports with default zeros
        loop lv from: 0 to: num_levels - 1 {
            level_occupancy  << 0;
            level_ev_ports   << 0;
            // Default: 30% of bays per level are EV-capable (11 kW)
        }
    }

    // ----------------------------------------------------------
    // Derived: total occupied spaces across all levels
    // ----------------------------------------------------------
    int total_occupied -> sum(level_occupancy);

    // ----------------------------------------------------------
    // Query: is the lot completely full?
    // ----------------------------------------------------------
    bool is_full -> total_occupied >= total_capacity;

    // ----------------------------------------------------------
    // Query: is a specific level full?
    // ----------------------------------------------------------
    bool is_level_full (int level) {
        if (level < 0 or level >= num_levels) { return true; } // Out of range → treat as full
        return level_occupancy[level] >= spaces_per_level;
    }

    // ----------------------------------------------------------
    // Query: find the lowest available level (ground up)
    // Returns -1 if every level is full.
    // ----------------------------------------------------------
    int find_available_level {
        loop lv from: 0 to: num_levels - 1 {
            if (level_occupancy[lv] < spaces_per_level) { return lv; }
        }
        return -1; // Fully occupied
    }

    // ----------------------------------------------------------
    // Action: vehicle enters a specific level
    // Called by the EV after it arrives at level_entry_points[lv].
    // Returns true if a space was secured, false if the level
    // filled up between the vehicle's arrival decision and entry.
    // ----------------------------------------------------------
    bool enter_level (int level, elecar ev) {
        if (level < 0 or level >= num_levels) { return false; }
        if (level_occupancy[level] >= spaces_per_level)  { return false; }
        level_occupancy[level] <- level_occupancy[level] + 1;
        return true;
    }

    // ----------------------------------------------------------
    // Action: vehicle leaves a specific level
    // ----------------------------------------------------------
    action leave_level (int level) {
        if (level >= 0 and level < num_levels) {
            level_occupancy[level] <- max(0, level_occupancy[level] - 1);
        }
    }

    // ----------------------------------------------------------
    // Query: does the level have an EV charging port free?
    // ----------------------------------------------------------
    bool has_ev_port (int level) {
        return false;
    }

    // ----------------------------------------------------------
    // Action: occupy / release an EV port on a given level
    // ----------------------------------------------------------
    action occupy_ev_port (int level) {
        if (level >= 0 and level < num_levels and level_ev_ports[level] > 0) {
            level_ev_ports[level] <- level_ev_ports[level] - 1;
        }
    }

    action release_ev_port (int level) {
        if (level >= 0 and level < num_levels) {
            // Cap at initial allocation (spaces_per_level * 0.3)
            int max_ports <- int(spaces_per_level * 0.3);
            level_ev_ports[level] <- min(max_ports, level_ev_ports[level] + 1);
        }
    }

    // ----------------------------------------------------------
    // Aspect: draw as a stacked-floor rectangle for the 3D view
    // ----------------------------------------------------------
    aspect base {
        loop lv from: 0 to: num_levels - 1 {
            // Each level is a semi-transparent layer offset upward
            float fill_ratio <- level_occupancy[lv] / float(spaces_per_level);
            rgb lvl_color <- rgb(int(200 * fill_ratio), int(200 * (1 - fill_ratio)), 80, 160);
            draw rectangle(30, 20) at: location + {0, 0, lv * 5}
                 color: lvl_color border: #black;
        }
    }
}


// ============================================================
// SPECIES: tower_building
// One half of a "twin tower" complex.  Each tower owns a
// parking_lot and keeps a reference to its sibling tower.
//
// Overflow logic (primary design goal):
//   1. A vehicle belonging to this tower first tries its own lot.
//   2. If the lot is full, it redirects to the twin's lot.
//   3. The twin lot is used only if it is not itself full.
//   4. The vehicle records which lot it actually parked in so it
//      can exit from the correct building.
//
// The entry/exit geometry mirrors the real-world scenario:
//   - Each tower has two ground-floor intersections:
//       entrance_intersection  – vehicles drive in here
//       exit_intersection      – vehicles leave from here
//   - Upper-level ramps share the same intersection by default
//     (can be overridden by assigning level_entry_points[lv] on
//     the owned parking_lot).
// ============================================================
species tower_building schedules: [] {

    // ----------------------------------------------------------
    // Identity & geometry
    // ----------------------------------------------------------
    string tower_name <- "Tower_A"; // Human-readable identifier
    int    tower_id   <- 0;         // 0 = Tower A, 1 = Tower B

    // Ground-floor entry and exit road intersections
    // (set during init in main.gaml after intersection agents exist)
    intersection entrance_intersection <- nil;
    intersection exit_intersection     <- nil;

    // ----------------------------------------------------------
    // Owned parking lot
    // ----------------------------------------------------------
    parking_lot my_parking <- nil; // Created and assigned in main.gaml

    // ----------------------------------------------------------
    // Twin reference (the other tower in the pair)
    // ----------------------------------------------------------
    tower_building twin_tower <- nil;

    // ----------------------------------------------------------
    // Helper: find the best lot for an arriving EV.
    // Returns `my_parking` if it has space, the twin's lot if not,
    // or nil if both are full.
    // ----------------------------------------------------------
    parking_lot find_available_lot {
        if (my_parking != nil and !my_parking.is_full) {
            return my_parking;           // Own lot has space → use it
        }
        if (twin_tower != nil
            and twin_tower.my_parking != nil
            and !twin_tower.my_parking.is_full) {
            return twin_tower.my_parking; // Overflow to twin
        }
        return nil; // Both lots full
    }

    // ----------------------------------------------------------
    // Helper: is this EV's home tower (i.e. should it try here first)?
    // We compare the EV's home building location against this tower's
    // entrance intersection proximity.
    // ----------------------------------------------------------
    bool is_home_tower (vehicle ev) {
        if (entrance_intersection = nil) { return false; }
        return (entrance_intersection distance_to ev.home) <
               (twin_tower = nil ? 9999.0 :
               (twin_tower.entrance_intersection = nil ? 9999.0 :
                twin_tower.entrance_intersection distance_to ev.home));
    }

    // ----------------------------------------------------------
    // Aspect
    // ----------------------------------------------------------
    aspect base {
        draw shape color: tower_id = 0 ? #lightblue : #lightyellow
             border: #navy depth: 40.0;
        draw string(tower_name) at: location + {0, 0, 45}
             font: font("Arial", 10, #bold) color: #black;
    }
}

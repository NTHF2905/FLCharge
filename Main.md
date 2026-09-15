// ============================================================
// FILE: main.gaml
// PURPOSE: Top-level model file that:
//   1. Imports Traffic.gaml (all species + shared globals)
//   2. Declares global variables specific to orchestration
//   3. Contains the `init` block that loads shapefiles and
//      spawns all agents
//   4. Manages the day/rush-hour lifecycle via reflexes
//   5. Exports daily statistics to CSV
//   6. Defines the GUI and headless experiment configurations
// ============================================================

model main

import "Traffic.gaml" // Pulls in all species and global variables defined in Traffic.gaml

global {
	int charging_stations <- 0; // Reserved counter for dynamically-added stations (UI parameter placeholder)

	// ----------------------------------------------------------
	// ACTION: clear_data
	// Destroys all dynamic agents and resets graph state.
	// Called at the start of init to ensure a clean slate,
	// and can be re-called between experiment runs.
	// ----------------------------------------------------------
	action clear_data {
		ask road         { do die; } // Remove all road segment agents
		ask car          { do die; } // Remove all ICE car agents
		ask private_ev   { do die; } // Remove all private EV agents
		ask taxi_ev      { do die; } // Remove all taxi EV agents
		ask charging_station { do die; } // Remove all charging station agents
		ask parking_lot  { do die; } // Remove all parking lot agents
		open_roads   <- [];   // Clear the list used to build the road network graph
		road_network <- nil;  // Release the graph object
		write "All data cleared.";
	}

	// --- Road / network state ---
	list<road> open_roads; // Subset of road agents currently active in the network;
	                       // passed to as_driving_graph() to build road_network

	// --- Display scaling ---
	float player_size_GAMA <- 20.0; // Generic display-scale factor (legacy; not actively used)

	// --- Asset paths ---
	//geometry shape <- envelope(resources_dir + "output_shapefile.shp"); // Commented: alternative world bounds
	string images_dir <- "../images/"; // Directory containing icon images (referenced by species)

	// --- Display colour palette (4-level for congestion heat-map, currently unused) ---
	list<rgb> pal <- palette([#green, #yellow, #orange, #red]);

	// --- Legend mapping for the 3D display ---
	map<rgb, string> legends <- [color_car::"Cars", color_road::"Roads", color_lake::"Rivers & Lakes", color_private::"Private EVs"];

	// --- Agent colour constants ---
	rgb color_car        <- #red;                     // ICE cars rendered in red
	rgb color_private    <- #yellow;                  // Private EVs rendered in yellow
	rgb color_taxi       <- #cyan;                    // Taxis rendered in cyan
	rgb color_road       <- #black;                   // Road segments rendered in black
	rgb color_lake       <- rgb(165, 199, 238, 255);  // Water bodies (light blue)
	rgb color_inner_building <- rgb(100, 100, 100);   // Interior building fill (dark grey)
	// rgb color_outer_building <- #black;            // Commented: outer building outline (moved to per-agent attribute)
	rgb color_charging_station <- #yellow;            // Charging station circle (overridden by aspect base → purple)

	// --- Rush-hour time windows (updated every step via `update:`) ---
	// Values are expressed as absolute simulation hours (day_hour offsets the clock per day):
	float rush_hour_start1 <- 5.5 + day_hour update: 5.5 + day_hour;  // Morning rush starts 05:30
	float rush_hour_start2 <- 17.0 + day_hour update: 17.0 + day_hour; // Evening rush starts 17:00
	float rush_hour_end1   <- 7.5 + day_hour update: 7.5 + day_hour;  // Morning rush ends 07:30
	float rush_hour_end2   <- 20.0 + day_hour update: 20.0 + day_hour; // Evening rush ends 20:00

	// --- Rush-hour agent lists ---
	list<vehicle> entertain_car    <- []; // (Legacy) was used to track entertainment vehicles separately
	bool rush      <- false; // true while a rush period is active
	bool rush_end  <- false; // true immediately after a rush period ends (triggers cleanup)
	list<vehicle> rush_vehi        <- []; // All rush-hour vehicles created in the current rush window
	list<vehicle> charge_rush_vehi <- []; // Subset of rush_vehi that need charging after rush ends

	float end_start <- 0.0; // Simulation hour when the post-rush staggered removal began
	int i <- 0;             // Index pointer used to step through rush_vehi one vehicle per tick during cleanup
	bool otherhalf  <- true; // true = evening rush window is eligible; mirrors `half` for the second rush
	bool have_rush  <- true; // Master toggle exposed as a UI parameter; set to false to disable all rush hours

	// --- Charging rate catalogue (kW) — shared with charging_station.find_available_port ---
	list<int> CHARGING_RATES <- [250, 180, 150, 60, 30, 11];

	// --- CSV export path ---
	string csv_file_path <- "../includes/accumulate_properties.csv"; // Output file for daily station statistics

	// --- Station and tracking lists ---
	list<charging_station> all_stations <- []; // Master list of all valid charging stations (built in create_all_station_list)
	list<int> served_pep <- [];                // Cumulative list of per-station served customer counts (populated by getting_served_customer)

	// --- Shapefile resource paths ---
	string resources_dir <- "../includes/"; // Base directory for all input shapefiles and data files
	shape_file buildings_shape_file      <- shape_file(resources_dir + "Middle.shp");  // Central district buildings
	shape_file add_buildings_shape_file  <- shape_file(resources_dir + "final.shp");   // Additional buildings layer
	shape_file top_buildings_shape_file  <- shape_file(resources_dir + "Part1.shp");   // Southern district buildings
	shape_file bottom_buildings_shape_file <- shape_file(resources_dir + "Part2.shp"); // Northern district buildings

	// --- World bounding box ---
	geometry shape <- envelope(buildings_shape_file);
	// Sets the simulation world size to the bounding box of the main buildings shapefile.
	// All agents are positioned within this spatial extent.

	// --- Population counts (baseline, non-rush) ---
	int chargebots <- 50;
	bool use_chargerbot_dispatch <- true; // true = elecar gọi chargerbot di động; false = hành vi cũ (tự lái tới station)
	int cars    <- 3000; // Total ICE cars in the baseline simulation
	int elecars <- 1732; // Total EVs (taxis + private combined)
	int taxis   <- 1138; // Number of taxi EVs (subset of elecars)
	int working_car  <- int(elecars * 0.3);   // 30% of EVs are "working" vehicles (rough categorisation)
	int privates     <- elecars - taxis; // Private EVs = total EVs minus taxis
	int rush_cars    <- cars * 0.5;      // Extra ICE cars spawned during rush: 50% of baseline
	int ev_rush      <- elecars * 0.5;   // Extra EVs spawned during rush: 50% of baseline EV count
	int working_rush <- working_car * 0.3; // Subset of rush EVs classified as working
	int rush_taxis   <- taxis * 0.5;     // Rush-hour taxi EV count
	int rush_privates <- ev_rush - rush_taxis; // Rush-hour private EV count
	int total_rush <- rush_taxis + rush_privates + rush_cars; // Grand total rush-hour vehicles

	int motos <- 0; // Motorbike count (species removed; kept as a zero placeholder)


	// ==========================================================
	// INIT BLOCK
	// Loads all shapefiles, builds the road network, classifies
	// buildings, and spawns the initial vehicle population.
	// ==========================================================
	init {
		do clear_data; // Ensure no stale agents from a prior run
		write "Simulation Start";

		// --- Load roads (bidirectional) ---
		create road from: shape_file(resources_dir + "line.shp");
		// Creates one road agent per polyline feature in the shapefile (forward direction).

		loop r over: road {
			create road with: (shape: polyline(reverse(r.shape.points)), name: r.name, type: r.type, chargeroad: r.chargeroad);
			// For every original road, create a reversed-direction copy so that the graph
			// has directed edges in BOTH directions (bidirectional road network).
		}

		// Debug: print names of all roads flagged as charge roads
		loop r over: road {
			if (r.chargeroad) {
				write r.name;
			}
		}

		// --- Initialise CSV export file (write header row) ---
		string headers <- "Day,Station_Name,Charging_Time,Average_Waiting_Time,Distance_Travel,Power_Consumed\n";
		save headers to: csv_file_path format: "text";
		// Creates (or overwrites) the output CSV with column headers.
		// Subsequent daily exports append rows with rewrite: false.

		// --- Initialise parking statistics CSV ---
		string parking_headers <- "Day,Tower,Level,Occupied_Spaces,Total_Spaces,EV_Ports_Free\n";
		save parking_headers to: "../includes/parking_stats.csv" format: "text";

		// --- Load buildings from all four shapefiles ---
		create building from: shape_file(buildings_shape_file);
		create building from: shape_file(add_buildings_shape_file);
		create building from: shape_file(top_buildings_shape_file);
		create building from: shape_file(bottom_buildings_shape_file);
		// Buildings are loaded in four tiles (Middle, final, Part1, Part2) because
		// the study area is split across separate shapefiles.

		// Note: the loop below duplicates every building — this may be a legacy
		// issue where build_type values needed to be copied after creation.
		loop b over: building {
			create building with: (build_type: b.build_type);
		}

		// --- Compute road lane counts based on nearest building ---
		ask road {
			agent ag <- building closest_to self; // Find the nearest building to this road segment
			float dist <- ag = nil ? 8.0 : max(min(ag distance_to self - 5.0, 8.0), 2.0);
			// Heuristic: wider distance from buildings → more likely a wide arterial road.
			// Clamped between 2.0 and 8.0 m to avoid extreme values.
			if (!chargeroad) {
				num_lanes <- int(dist / lane_width);
				// Converts the estimated road width to a lane count.
				// e.g. dist = 6.0, lane_width = 1.0 → 6 lanes
			}
			capacity <- 1 + (num_lanes * shape.perimeter / 3);
			// Recalculate capacity after lane count is known.
		}

		// --- Commented-out block: uniform building type assignment ---
		// This was an alternative approach that shuffled all buildings and
		// assigned them to types 1/2/3 in equal thirds. Replaced by shapefile-driven
		// build_type attributes and the colour loop below.

		// --- Assign building display colours by type ---
		loop b over: building {
			b.color_outer_building <- b.build_type = 1 ? #blue : (b.build_type = 2 ? #green : #gray);
			// Type 1 (residential) = blue, Type 2 (workplace) = green, Type 3 (commercial) = gray
		}

		// --- Finalise road network ---
		open_roads <- list(road); // Populate open_roads with all roads (full network, no closures)
		do create_all_station_list; // Load charging stations from shapefile and populate all_stations
		do update_road(0);          // Build the road graph and assign closest intersections
		write "intersection " + length(intersection); // Debug: confirm intersection count

		// --- Classify buildings into typed lists for vehicle spawning ---
		loop b over: building {
			if (b.build_type = 1) {
				buildings_type_1 << b; // Residential — spawn origin for all vehicles
			} else if (b.build_type = 2) {
				buildings_type_2 << b; // Workplace — destination for work commuters
			} else {
				buildings_type_3 << b; // Commercial — destination for leisure/food trips
			}
		}

		// --- Spawn vehicle populations ---
		do update_car_population(cars);            // Create `cars` ICE car agents
		do update_taxi_population(taxis);          // Create `taxis` taxi EV agents
		do update_private_population(privates);    // Create `privates` private EV agents

		// --- Spawn chargerbot fleet (mobile Edge robots) ---
		// Rải đều tại vị trí các charging_station hiện có — mỗi bot bắt đầu ở
		// trạng thái "idle" và đầy pin (giá trị mặc định trong species).
		if (!empty(all_stations)) {
			create chargerbot number: chargebots with: [
				location::one_of(all_stations).location
			];
		} else {
			write "Canh bao: khong co charging_station nao, bo qua spawn chargerbot.";
		}

		// --- Assign behaviour type to ICE cars (work vs entertainment) ---
		loop c over: car {
			c.is_entertainment_car <- flip(0.3) ? true : false;
			// 30% probability of being a leisure vehicle
			if c.is_entertainment_car = false {
				c.is_work_car <- true; // All non-entertainment cars are work commuters
			}
		}

		// --- Assign behaviour type to private EVs ---
		loop c over: private_ev {
			c.is_entertainment_car <- flip(0.3) ? true : false;
			if c.is_entertainment_car = false {
				c.is_work_car <- true;
			}
		}
	}


	// ==========================================================
	// REFLEX: export_daily_statistics
	// Triggered once per simulated day (when simulation_hour
	// crosses the next 24-hour boundary).
	// Writes per-station statistics to the CSV and increments day_counter.
	// ==========================================================
	reflex export_daily_statistics when: simulation_hour >= (day_counter * 24) {
		loop station over: all_stations {
			// Collect station metrics:
			float avg_waiting_time      <- station.get_average_waiting_time();  // Avg hours waited per vehicle
			float vehicles_charging_time <- station.get_average_charging_time(); // Avg hours charged per vehicle
			float vehicles_distance_travel <- station.total_distance_travel;     // Total m driven to this station
			float station_power_consumed   <- station.power_consumed;            // Total kWh delivered
			string station_name            <- station.name;                      // Station identifier string

			// Build a CSV row and append to file:
			string line <- "" + day_counter + "," + station_name + "," + vehicles_charging_time + ","
			             + avg_waiting_time + "," + vehicles_distance_travel + "," + station_power_consumed + "\n";
			save line to: csv_file_path format: 'text' rewrite: false; // rewrite:false = append mode

			// Commented-out block: daily counter reset was disabled so statistics accumulate
			// across days rather than resetting — useful for multi-day trend analysis.
		}
		// Commented-out: export map screenshot at end of day
		// export file: "output/map_%step%.png" type: png display: "Chart";

		day_counter <- day_counter + 1; // Advance to next day
		do clear(); // Remove lingering rush-hour vehicles from charge_rush_vehi

		// --- Export daily parking occupancy for each tower ---
	}

	// Commented-out reflex: auto-pause after 2 days (useful for debugging headless runs)


	// ==========================================================
	// REFLEX: update_half
	// Runs once per day (between simulation_hour + 1.0 and + 2.0,
	// i.e. 01:00–02:00 of each day) to randomise the next day's
	// vehicle schedules. The `half` flag prevents it firing again.
	// ==========================================================
	reflex update_half when: half = false and simulation_hour > day_hour + 1.0 and simulation_hour < day_hour + 2.0 {
		half <- true; // Prevent re-triggering until next morning rush resets it

		// Re-randomise day_start (5:00–7:30) and day_end (20:00–24:00) for all vehicle types:
		loop vehi over: list(car)       { vehi.day_start <- rnd(5.0 + day_hour, 7.5 + day_hour);  vehi.day_end <- rnd(20.0 + day_hour, 24.0 + day_hour); }
		loop vehi over: list(taxi_ev)   { vehi.day_start <- rnd(5.0 + day_hour, 7.5 + day_hour);  vehi.day_end <- rnd(20.0 + day_hour, 24.0 + day_hour); }
		loop vehi over: list(private_ev){ vehi.day_start <- rnd(5.0 + day_hour, 7.5 + day_hour);  vehi.day_end <- rnd(20.0 + day_hour, 24.0 + day_hour); }
	}


	// ==========================================================
	// POPULATION MANAGEMENT ACTIONS
	// Each update_*_population action reconciles the current
	// agent count with the requested number by killing excess
	// agents (delta > 0) or creating new ones (delta < 0).
	// ==========================================================

	action update_car_population (int new_number) {
		int delta <- length(car) - new_number; // Positive = too many, negative = too few
		if (delta > 0) {
			ask delta among car { do unregister; do die; }
			// unregister removes the car from the driving skill's road occupancy tracking before dying
		} else if (delta < 0) {
			create car number: -delta with: [location::one_of(buildings_type_1).location];
			// Spawn missing cars at random residential buildings
		}
	}

	action update_rush_car_population (int new_number) {
		// Rush cars are always created fresh (no delta logic) because they are
		// temporary agents that will be removed at rush end.
		create rush_hour_car number: new_number with: [location::one_of(buildings_type_1).location];
	}

	// ----------------------------------------------------------
	// ACTION: create_all_station_list
	// Loads charging stations from the shapefile and populates
	// `all_stations` with only those that have at least one port.
	// ----------------------------------------------------------
	action create_all_station_list {
		create charging_station from: shape_file(resources_dir + "temporary_cs.shp") with: [
			name    :: string(read("temp_name")), // Station identifier (e.g. "CS_001")
			Address :: string(read("Name")),      // Human-readable name/address
			port_250 :: int(read("Port_250KW")),  // Number of 250 kW DC ports
			port_180 :: int(read("Port_180KW")),  // Number of 180 kW DC ports
			port_150 :: int(read("Port_150KW")),  // Number of 150 kW DC ports
			port_60  :: int(read("Port_60KW")),   // Number of 60 kW AC ports
			port_30  :: int(read("Port_30KW")),   // Number of 30 kW AC ports
			port_11  :: int(read("Port_11KW"))    // Number of 11 kW AC slow-charge ports
		];
		// Only add stations that have at least one port of any type to all_stations:
		loop cs over: list(charging_station) {
			if (cs.port_250 > 0 or cs.port_180 > 0 or cs.port_150 > 0
			    or cs.port_60 > 0 or cs.port_30 > 0 or cs.port_11 > 0) {
				add cs to: all_stations;
			}
		}
	}


	// ==========================================================
	// REFLEX: update_rush
	// State machine that manages the rush/rush_end/half/otherhalf
	// flags based on the current simulation_hour.
	// Transitions:
	//   Idle → rush (morning): hour > rush_hour_start1 and half=true
	//   Rush → idle (morning): hour > rush_hour_end1   → resets half, enables otherhalf
	//   Idle → rush (evening): hour > rush_hour_start2 and otherhalf=true
	//   Rush → idle (evening): hour > rush_hour_end2   → disables otherhalf
	// ==========================================================
	reflex update_rush {
		// --- Morning rush onset ---
		if (simulation_hour > rush_hour_start1 and rush = false and half) {
			rush     <- true;
			rush_end <- false;
			rush_vehi        <- []; // Clear vehicle tracking for this new rush window
			charge_rush_vehi <- [];
		}
		// --- Evening rush onset ---
		if (simulation_hour > rush_hour_start2 and rush = false and otherhalf) {
			rush_end <- false;
			rush_vehi <- [];
			rush     <- true;
		}
		// --- Morning rush end ---
		if (simulation_hour > rush_hour_end1 and rush = true and half) {
			rush_end  <- true;   // Signal cleanup phase
			half      <- false;  // Morning rush window consumed
			i         <- 0;      // Reset vehicle-removal index
			otherhalf <- true;   // Unlock evening rush
			rush      <- false;
		}
		// --- Evening rush end ---
		if (simulation_hour > rush_hour_end2 and rush = true) {
			otherhalf <- false;  // Evening rush window consumed
			rush      <- false;
			rush_end  <- true;
			i         <- 0;
		}
	}


	// ==========================================================
	// REFLEX: rush_hour
	// Fires while rush=true (and have_rush=true to allow disabling).
	// Creates the rush-hour vehicle surge if rush_vehi has not
	// yet been populated for this window.
	// ==========================================================
	reflex rush_hour when: rush and have_rush {
		end_start <- 0.0; // Reset the staggered-removal timer
		if (length(rush_vehi) < total_rush) {
			write 'ok'; // Debug: confirm rush vehicles are being created
			do update_rush_car_population(rush_cars);           // Create extra ICE cars
			do update_rush_taxi_population(rush_taxis);         // Create extra taxi EVs
			do update_rush_private_population(rush_privates);   // Create extra private EVs
			// Add all newly created rush agents to rush_vehi for tracking:
			loop vehi over: list(rush_hour_car)     { rush_vehi << vehi; }
			loop vehi over: list(rush_hour_private) { rush_vehi << vehi; }
			loop vehi over: list(rush_hour_taxi)    { rush_vehi << vehi; }
		}
	}


	// ==========================================================
	// REFLEX: rush_hour_end
	// Staggered removal of rush vehicles after rush_end is set.
	// Vehicles are removed one-per-step (via index i) rather than
	// all at once, to avoid a sudden population drop.
	// EVs that need charging are saved to charge_rush_vehi instead
	// of being immediately killed.
	// ==========================================================
	reflex rush_hour_end when: rush_end {
		if (end_start = 0.0) {
			end_start <- simulation_hour;
			end_start <- end_start + step / 30; // Schedule first removal step/30 hours after rush end
		}
		if (simulation_hour > end_start and i < length(rush_vehi)) {
			if (length(rush_vehi) != 0) {
				if (not dead(rush_vehi[i]) and rush_vehi[i].needs_charging) {
					charge_rush_vehi << rush_vehi[i]; // Preserve EVs that still need charging
				} else {
					ask rush_vehi[i] { do die; } // Kill vehicles that don't need charging
				}
				i         <- i + 1;              // Advance to next vehicle
				end_start <- end_start + step / 30; // Schedule next removal
			}
			write rush_vehi; // Debug: print remaining rush vehicle list
		}
	}


	// ==========================================================
	// ACTION: clear
	// Removes the first vehicle in charge_rush_vehi.
	// Called once per day by export_daily_statistics to drain
	// the list of rush EVs that finished their charge.
	// ==========================================================
	action clear {
		int s <- 0;
		if (length(charge_rush_vehi) != 0 and s < length(charge_rush_vehi)) {
			ask charge_rush_vehi[s] { do die; }
			s <- s + 1;
		}
	}


	// ==========================================================
	// ACTION: getting_served_customer
	// Collects the served_customer count from each station into
	// the global served_pep list. Used for reporting.
	// ==========================================================
	action getting_served_customer {
		loop station over: list(all_stations) {
			add station.served_customer to: served_pep;
		}
	}


	// --- EV population management actions ---

	action update_taxi_population (int new_number) {
		int delta <- length(taxi_ev) - new_number;
		if (delta > 0) {
			ask delta among taxi_ev { do unregister; do die; }
		} else if (delta < 0) {
			create taxi_ev number: -delta with: [all_stations::all_stations, location::one_of(buildings_type_1).location];
			// Taxis are passed `all_stations` so they can independently select a charging station.
		}
	}

	action update_private_population (int new_number) {
		int delta <- length(private_ev) - new_number;
		if (delta > 0) {
			ask delta among private_ev { do unregister; do die; }
		} else if (delta < 0) {
			create private_ev number: -delta with: (all_stations::all_stations, location::one_of(buildings_type_1).location);
		}
	}

	action update_rush_private_population (int new_number) {
		create rush_hour_private number: new_number with: (all_stations::all_stations, location::one_of(buildings_type_1).location);
	}

	action update_rush_taxi_population (int new_number) {
		create rush_hour_taxi number: new_number with: (all_stations::all_stations, location::one_of(buildings_type_1).location);
	}

	// ==========================================================
	// ACTION: update_road
	// Rebuilds the intersection agents and road_network graph.
	// Should be called whenever open_roads changes (road closures,
	// scenario changes, or initial setup).
	// Parameter `scenario` is reserved for future road-closure logic.
	// ==========================================================
	action update_road (int scenario) {
		// Step 1: Clear existing spatial references so they can be re-assigned
		ask building         { closest_intersection <- nil; }
		ask charging_station { closest_intersection <- nil; }

		// Step 2: Kill all current intersection agents (they will be recreated from scratch)
		ask intersection { do die; }

		// Step 3: Derive intersection nodes from road geometry
		graph g <- as_edge_graph(open_roads); // Build a temporary graph to extract vertex points
		loop pt over: g.vertices {
			create intersection with: (shape: pt);
			// One intersection agent per unique vertex in the road network
		}

		// Step 4: Re-assign closest intersections to buildings and charging stations
		ask building {
			closest_intersection <- intersection closest_to self;
		}
		ask agents of_generic_species charging_station {
			closest_intersection <- intersection closest_to self;
			// of_generic_species handles all subclasses of charging_station
		}

		// Step 5: Reset vehicle ordering on roads (clears any stale queue state)
		ask road { vehicle_ordering <- nil; }

		// Step 6: Give charge roads unlimited capacity so EV routing is never blocked
		ask road {
			if (chargeroad) {
				capacity  <- 10000.0;
				num_lanes <- 10000;
				// These extreme values ensure the speed_coeff stays near 1.0
				// regardless of how many EVs are on the approach to a charger.
			}
		}

		// Step 7: Build the final directed driving graph using FloydWarshall shortest paths
		road_network <- as_driving_graph(open_roads, intersection) with_shortest_path_algorithm #FloydWarshall;
		// FloydWarshall pre-computes all-pairs shortest paths at init time,
		// which is slower to initialise than Dijkstra but faster per query — suitable for
		// large populations of vehicles all querying paths simultaneously.

		ask agents of_generic_species vehicle {
			// Placeholder: vehicles could re-compute paths here if needed after a network change
		}
	}
}


// ============================================================
// EXPERIMENT: "Run me"   (interactive GUI)
// The primary experiment for manual exploration.
// Provides sliders and toggles for all key parameters,
// and three output displays: statistics charts, inconvenience
// parameters, and a 3D spatial view.
// ============================================================
experiment "Run me" type: gui {
	float maximum_cycle_duration <- 0.2; // Cap simulation speed to 0.2 s per cycle (prevents UI freezing)

	// --- Population sliders ---
	parameter "Cars" category: "Param" var: cars slider: true min: 0 max: 2000 {
		ask world { do update_car_population(cars); } // Live-update car count when slider moves
	}
	parameter "ElectricVehi" category: "Param" var: elecars slider: true min: 0 max: 2000 {
		ask world {
			do update_taxi_population(taxis);
			do update_private_population(privates);
		}
	}

	// --- Station/charging parameters ---
	parameter "ChargingPort" category: "Param" var: vehi_capacity slider: true min: 0 max: 50 {
		// Controls the legacy per-station port cap (vehi_capacity); changing this
		// does not rebuild station port counts from the shapefile.
	}
	parameter "% Charge_Night For Taxi" category: "Param" var: percent_charge slider: true min: 0.0 max: 1.0 {
		// Probability that a taxi charges at a depot overnight (0.0–1.0)
	}
	parameter "% Charge_Home for Private" category: "Param" var: proba_charge_home slider: true min: 0.0 max: 1.0 {
		// Probability that a private EV with battery < 90% decides to charge at home
	}
	parameter "Use Chargerbot Dispatch" category: "Param" var: use_chargerbot_dispatch {
		// true = elecar goi chargerbot di dong khi can sac; false = hanh vi cu (tu lai toi station)
		// Bat/tat de so sanh A/B: he thong CMEI moi vs baseline fixed-station.
	}

	// --- Speed parameters ---
	parameter "Car Speed"     category: "Speed" var: car_speed     slider: true min: 0.0 max: 200.0 {}
	parameter "Ele_car Speed" category: "Speed" var: ele_car_speed slider: true min: 0.0 max: 200.0 {}

	// --- Battery consumption parameters ---
	parameter "SoC Consumption Max" category: "SoC Consumption" var: bat_cons_max slider: true min: 0.0 max: 1.0 {}
	parameter "SoC Consumption Min" category: "SoC Consumption" var: bat_cons_min slider: true min: 0.0 max: 1.0 {}

	// --- Convenience-factor coefficients ---
	parameter "Charging Coefficient" var: charging_coef category: "Convenience Coefficient"; // Weight on charging time
	parameter "Waiting Coefficient"  var: waiting_coef  category: "Convenience Coefficient"; // Weight on waiting time
	parameter "Distance Coefficient" var: distance_coef category: "Convenience Coefficient"; // Weight on travel distance

	// --- Rush hour toggle ---
	parameter "Rush Activity" category: "Bool" var: have_rush;
	// Set to false to run the simulation without rush-hour vehicle surges

	// --- Twin-tower parking parameters ---

	// Note: changing these after init has no effect on already-created parking_lot agents.
	// Re-run the simulation (do clear_data + re-init) to apply structural changes.


	// --- Output section ---
	output synchronized: true {
		layout 1 consoles: false controls: true navigator: false editors: false toolbars: false;
		// Layout 1 = single main panel; suppresses unnecessary GAMA panels for a cleaner view

		// --- Chart display: station throughput and quality metrics ---
		display "Chart" type: 2d refresh: every(10 #cycle) {
			chart "Amount of customer served" type: histogram size: {0.5, 0.5} position: {0, 0.5} {
				// Bottom-left: bar chart of total served customers per station
				datalist charging_station collect (each.name) value: charging_station collect (each.served_customer);
			}
			chart "Convenience Factor" type: histogram size: {1.0, 0.5} {
				// Top half (full width): composite inconvenience score per station (lower = better)
				datalist charging_station collect (each.name) value: charging_station collect (each.convenience_factor);
			}
			chart "Power_consumption" type: series size: {0.5, 0.5} position: {0.5, 0.5} {
				// Bottom-right: time-series of cumulative kWh per station
				datalist charging_station collect (each.name) value: charging_station collect (each.power_consumed);
			}
		}

		// --- Chart display: waiting, charging, and distance statistics ---
		display "Inconvenience Parameters" type: 2d refresh: every(10 #cycle) {
			chart "Avg Total Waiting Time" type: histogram size: {0.5, 0.5} position: {0, 0.5} {
				// Bottom-left: average hours waited per vehicle, per station
				datalist charging_station collect (each.name) value: charging_station collect (each.get_average_waiting_time());
			}
			chart "Avg Total Charging Time" type: histogram size: {1.0, 0.5} {
				// Top (full width): average charging session duration per station
				datalist charging_station collect (each.name) value: charging_station collect (each.get_average_charging_time());
			}
			chart "Avg Total Distance Travel" type: histogram size: {0.5, 0.5} position: {0.5, 0.5} {
				// Bottom-right: average distance (m) driven to reach each station
				datalist charging_station collect (each.name) value: charging_station collect (each.get_total_distance());
			}
		}

		// --- 3D spatial display ---
		display Computer virtual: false type: 3d toolbar: true background: #white axes: false antialias: false {
			// `virtual: false` = render to screen; `antialias: false` for performance

			species road {
				draw self.shape + 1 color: color_road;
				// Draw road geometry inflated by 1 m (so thin roads remain visible)
			}

			// Vehicle species (rendered via their `icon` aspect — an image scaled to `size`):
			species car              	aspect: icon;
			species private_ev       	aspect: icon;
			species taxi_ev          	aspect: icon;
			species rush_hour_car    	aspect: icon;
			species rush_hour_private 	aspect: icon;
			species rush_hour_taxi   	aspect: icon;

			species building {
				draw self.shape color: color_outer_building; // Filled polygon per build_type colour
			}

			species charging_station aspect: base; // Purple circle (from aspect base in Traffic.gaml)
			species chargerbot       aspect: icon; // Orange circle — mobile Edge robot fleet
			species intersection;                  // Default aspect: small green circle (from Traffic.gaml)
		}
	}
}


// ============================================================
// EXPERIMENT: "Headless Runme"
// Batch/headless run that auto-starts and stops after 2 days.
// Produces an auto-saved chart image at the end.
// Used for automated pipeline runs (e.g. Docker / CI).
// ============================================================
experiment "Headless Runme" autorun: true type: batch until: (day_counter = 2) {
	output synchronized: true {
		display "chart" type: 2d refresh: every(10 #cycle) autosave: day_counter = 2 {
			// `autosave: day_counter = 2` saves the chart to disk when the condition is true
			chart "Amount of customer served" type: histogram size: {0.5, 0.5} position: {0, 0.5} {
				datalist charging_station collect (each.name) value: charging_station collect (each.served_customer);
			}
			chart "Convenience Factor" type: histogram size: {1.0, 0.5} {
				datalist charging_station collect (each.name) value: charging_station collect (each.convenience_factor);
			}
			chart "Power_consumption" type: series size: {0.5, 0.5} position: {0.5, 0.5} {
				datalist charging_station collect (each.name) value: charging_station collect (each.power_consumed);
			}
		}
	}
}


// ============================================================
// EXPERIMENT: "Display Lost EV"
// Minimal GUI experiment for debugging stranded EVs.
// Renders only roads and buildings (no vehicles or stations)
// so the spatial layout can be inspected without the full
// simulation overhead.
// ============================================================
experiment "Display Lost EV" type: gui {
	species road {
		draw self.shape + 4 color: color_road; // Thicker roads (4 m) for easier viewing
	}
	species building {
		draw self.shape color: color_outer_building;
	}
}

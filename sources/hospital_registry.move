module selora::hospital_registry {
    use iota::event;
    use iota::table::{Self, Table};
    use std::string::String;

    const E_NOT_ADMIN:         u64 = 4001;
    const E_NOT_VERIFIED:      u64 = 4002;
    const E_ALREADY_REGISTERED: u64 = 4003;

    const TIER_SCAN_ONLY:   u8 = 1;
    const TIER_STARTER:     u8 = 2;
    const TIER_PROFESSIONAL: u8 = 3;
    const TIER_ENTERPRISE:  u8 = 4;

    public struct Hospital has store {
        hospital_id:  String,
        name:         String,
        country:      String,
        is_verified:  bool,
        verified_at:  Option<u64>,
        tier:         u8,
        total_scans:  u64,
        registered_at: u64,
    }

    public struct ScanEvent has store, drop {
        scan_id:      String,
        hospital_id:  String,
        patient_hash: String, // hashed patient ID — never raw address
        scope:        u8,
        timestamp:    u64,
    }

    public struct HospitalRegistry has key {
        id:              UID,
        admin:           address,
        hospitals:       Table<String, Hospital>,
        scan_log:        Table<String, ScanEvent>,
        total_hospitals: u64,
        total_scans:     u64,
    }

    public struct HospitalRegistered has copy, drop {
        hospital_id: String,
        name:        String,
        country:     String,
        timestamp:   u64,
    }

    public struct HospitalVerified has copy, drop {
        hospital_id: String,
        timestamp:   u64,
    }

    public struct ScanRecorded has copy, drop {
        scan_id:      String,
        hospital_id:  String,
        patient_hash: String,
        scope:        u8,
        timestamp:    u64,
    }

    public fun create_registry(ctx: &mut TxContext): HospitalRegistry {
        HospitalRegistry {
            id: object::new(ctx),
            admin: tx_context::sender(ctx),
            hospitals: table::new(ctx),
            scan_log: table::new(ctx),
            total_hospitals: 0,
            total_scans: 0,
        }
    }

    public fun register_hospital(
        registry: &mut HospitalRegistry,
        hospital_id: String,
        name: String,
        country: String,
        ctx: &mut TxContext,
    ) {
        assert!(!table::contains(&registry.hospitals, hospital_id), E_ALREADY_REGISTERED);
        let hospital = Hospital {
            hospital_id, name, country,
            is_verified: false,
            verified_at: option::none(),
            tier: TIER_SCAN_ONLY,
            total_scans: 0,
            registered_at: tx_context::epoch(ctx),
        };
        table::add(&mut registry.hospitals, hospital_id, hospital);
        registry.total_hospitals = registry.total_hospitals + 1;
        event::emit(HospitalRegistered {
            hospital_id, name, country,
            timestamp: tx_context::epoch(ctx),
        });
    }

    public fun verify_hospital(
        registry: &mut HospitalRegistry,
        hospital_id: String,
        ctx: &mut TxContext,
    ) {
        assert!(registry.admin == tx_context::sender(ctx), E_NOT_ADMIN);
        let hospital = table::borrow_mut(&mut registry.hospitals, hospital_id);
        hospital.is_verified = true;
        hospital.verified_at = option::some(tx_context::epoch(ctx));
        event::emit(HospitalVerified { hospital_id, timestamp: tx_context::epoch(ctx) });
    }

    public fun record_scan(
        registry: &mut HospitalRegistry,
        scan_id: String,
        hospital_id: String,
        patient_hash: String,
        scope: u8,
        ctx: &mut TxContext,
    ) {
        let hospital = table::borrow_mut(&mut registry.hospitals, hospital_id);
        assert!(hospital.is_verified, E_NOT_VERIFIED);
        hospital.total_scans    = hospital.total_scans + 1;
        registry.total_scans    = registry.total_scans + 1;
        let scan = ScanEvent { scan_id, hospital_id, patient_hash, scope, timestamp: tx_context::epoch(ctx) };
        table::add(&mut registry.scan_log, scan_id, scan);
        event::emit(ScanRecorded { scan_id, hospital_id, patient_hash, scope, timestamp: tx_context::epoch(ctx) });
    }

    public fun upgrade_hospital_tier(
        registry: &mut HospitalRegistry,
        hospital_id: String,
        new_tier: u8,
        ctx: &mut TxContext,
    ) {
        assert!(registry.admin == tx_context::sender(ctx), E_NOT_ADMIN);
        let hospital = table::borrow_mut(&mut registry.hospitals, hospital_id);
        hospital.tier = new_tier;
    }

    public fun is_hospital_verified(registry: &HospitalRegistry, hospital_id: String): bool {
        if (!table::contains(&registry.hospitals, hospital_id)) return false;
        table::borrow(&registry.hospitals, hospital_id).is_verified
    }
}

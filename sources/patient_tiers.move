module selora::patient_tiers {
    use iota::event;
    use iota::table::{Self, Table};

    const E_NOT_ADMIN:       u64 = 5001;
    const E_EARLY_ACCESS_PROTECTED: u64 = 5002;

    const TIER_FREE:         u8 = 1;
    const TIER_PREMIUM:      u8 = 2;
    const TIER_EARLY_ACCESS: u8 = 3; // Founding cohort — cannot be downgraded

    public struct PatientTier has store {
        patient:         address,
        tier:            u8,
        upgraded_at:     u64,
        is_early_access: bool,
    }

    public struct TierRegistry has key {
        id:    UID,
        admin: address,
        tiers: Table<address, PatientTier>,
    }

    public struct TierUpgraded has copy, drop {
        patient:   address,
        old_tier:  u8,
        new_tier:  u8,
        timestamp: u64,
    }

    public struct TierDowngraded has copy, drop {
        patient:   address,
        old_tier:  u8,
        new_tier:  u8,
        timestamp: u64,
    }

    public fun create_registry(ctx: &mut TxContext): TierRegistry {
        TierRegistry {
            id: object::new(ctx),
            admin: tx_context::sender(ctx),
            tiers: table::new(ctx),
        }
    }

    public fun register_patient(registry: &mut TierRegistry, ctx: &mut TxContext) {
        let patient = tx_context::sender(ctx);
        if (table::contains(&registry.tiers, patient)) return;
        let entry = PatientTier {
            patient,
            tier: TIER_FREE,
            upgraded_at: tx_context::epoch(ctx),
            is_early_access: false,
        };
        table::add(&mut registry.tiers, patient, entry);
    }

    public fun upgrade_tier(
        registry: &mut TierRegistry,
        patient: address,
        new_tier: u8,
        ctx: &mut TxContext,
    ) {
        assert!(registry.admin == tx_context::sender(ctx), E_NOT_ADMIN);
        let entry = table::borrow_mut(&mut registry.tiers, patient);
        let old = entry.tier;
        entry.tier = new_tier;
        entry.upgraded_at = tx_context::epoch(ctx);
        if (new_tier == TIER_EARLY_ACCESS) {
            entry.is_early_access = true;
        };
        event::emit(TierUpgraded { patient, old_tier: old, new_tier, timestamp: tx_context::epoch(ctx) });
    }

    public fun downgrade_tier(
        registry: &mut TierRegistry,
        patient: address,
        new_tier: u8,
        ctx: &mut TxContext,
    ) {
        assert!(registry.admin == tx_context::sender(ctx), E_NOT_ADMIN);
        let entry = table::borrow_mut(&mut registry.tiers, patient);
        // Early access patients can never be downgraded — founding cohort promise
        assert!(!entry.is_early_access, E_EARLY_ACCESS_PROTECTED);
        let old = entry.tier;
        entry.tier = new_tier;
        event::emit(TierDowngraded { patient, old_tier: old, new_tier, timestamp: tx_context::epoch(ctx) });
    }

    public fun get_tier(registry: &TierRegistry, patient: address): u8 {
        if (!table::contains(&registry.tiers, patient)) return TIER_FREE;
        table::borrow(&registry.tiers, patient).tier
    }

    public fun is_premium(registry: &TierRegistry, patient: address): bool {
        let tier = get_tier(registry, patient);
        tier == TIER_PREMIUM || tier == TIER_EARLY_ACCESS
    }
}
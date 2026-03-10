module selora::earnings_vault {
    use iota::event;
    use iota::balance::{Self, Balance};
    use iota::iota::IOTA;
    use iota::coin::{Self, Coin};
    use iota::table::{Self, Table};
    use std::string::String;

    const E_NOT_OWNER:         u64 = 7001;
    const E_NOTHING_TO_WITHDRAW: u64 = 7003;
    const E_NOT_GUARDIAN:      u64 = 7004;
    const E_RECOVERY_NOT_READY: u64 = 7005;
    const E_ALREADY_GUARDIAN:  u64 = 7006;
    const E_TOO_MANY_GUARDIANS: u64 = 7007;

    const RECOVERY_THRESHOLD:     u64 = 2; // 2-of-3 guardians required
    const RECOVERY_WINDOW_EPOCHS: u64 = 7; // 7 days to collect confirmations
    const MAX_GUARDIANS:          u64 = 3;

    public struct Guardian has store, drop {
        guardian_address: address,
        confirmed_at:     Option<u64>,
    }

    // drop removed — Table does not have drop, so RecoveryRequest cannot either
    public struct RecoveryRequest has store {
        new_owner:     address,
        initiated_at:  u64,
        confirmations: u64,
        guardians:     Table<address, Guardian>,
        is_complete:   bool,
    }

    public struct EarningsVault has key {
        id:                    UID,
        owner:                 address,
        pending_mist:          Balance<IOTA>,
        lifetime_earned_mist:  u64, // only ever increases — financial audit trail
        lifetime_withdrawn_mist: u64,
        guardians:             vector<address>,
        active_recovery:       Option<RecoveryRequest>,
    }

    public struct EarningsDeposited has copy, drop {
        patient:     address,
        amount_mist: u64,
        study_id:    String,
        timestamp:   u64,
    }

    public struct EarningsWithdrawn has copy, drop {
        patient:     address,
        amount_mist: u64,
        timestamp:   u64,
    }

    public struct GuardianAdded has copy, drop {
        patient:   address,
        guardian:  address,
        timestamp: u64,
    }

    public struct RecoveryInitiated has copy, drop {
        patient:   address,
        new_owner: address,
        timestamp: u64,
    }

    public struct RecoveryConfirmed has copy, drop {
        patient:       address,
        guardian:      address,
        confirmations: u64,
        timestamp:     u64,
    }

    public struct RecoveryCompleted has copy, drop {
        old_owner: address,
        new_owner: address,
        timestamp: u64,
    }

    public fun create_vault(ctx: &mut TxContext): EarningsVault {
        EarningsVault {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            pending_mist: balance::zero(),
            lifetime_earned_mist: 0,
            lifetime_withdrawn_mist: 0,
            guardians: vector::empty(),
            active_recovery: option::none(),
        }
    }

    /// Called by backend after research_marketplace::distribute_to_participant
    public fun deposit(
        vault: &mut EarningsVault,
        payment: Coin<IOTA>,
        study_id: String,
        ctx: &mut TxContext,
    ) {
        let amount = coin::value(&payment);
        balance::join(&mut vault.pending_mist, coin::into_balance(payment));
        vault.lifetime_earned_mist = vault.lifetime_earned_mist + amount;
        event::emit(EarningsDeposited {
            patient: vault.owner, amount_mist: amount, study_id,
            timestamp: tx_context::epoch(ctx),
        });
    }

    /// Withdraw full balance — balance zeroed BEFORE transfer (re-entrancy protection)
    public fun withdraw(vault: &mut EarningsVault, ctx: &mut TxContext): Coin<IOTA> {
        assert!(vault.owner == tx_context::sender(ctx), E_NOT_OWNER);
        let amount = balance::value(&vault.pending_mist);
        assert!(amount > 0, E_NOTHING_TO_WITHDRAW);
        vault.lifetime_withdrawn_mist = vault.lifetime_withdrawn_mist + amount;
        event::emit(EarningsWithdrawn { patient: vault.owner, amount_mist: amount, timestamp: tx_context::epoch(ctx) });
        coin::from_balance(balance::split(&mut vault.pending_mist, amount), ctx)
    }

    /// Withdraw a specific amount
    public fun withdraw_partial(
        vault: &mut EarningsVault,
        amount: u64,
        ctx: &mut TxContext,
    ): Coin<IOTA> {
        assert!(vault.owner == tx_context::sender(ctx), E_NOT_OWNER);
        assert!(balance::value(&vault.pending_mist) >= amount, E_NOTHING_TO_WITHDRAW);
        vault.lifetime_withdrawn_mist = vault.lifetime_withdrawn_mist + amount;
        event::emit(EarningsWithdrawn { patient: vault.owner, amount_mist: amount, timestamp: tx_context::epoch(ctx) });
        coin::from_balance(balance::split(&mut vault.pending_mist, amount), ctx)
    }

    // ─── Social Recovery (2-of-3 guardians) ──────────────────────────────────

    public fun add_guardian(vault: &mut EarningsVault, guardian: address, ctx: &mut TxContext) {
        assert!(vault.owner == tx_context::sender(ctx), E_NOT_OWNER);
        assert!((vector::length(&vault.guardians) as u64) < MAX_GUARDIANS, E_TOO_MANY_GUARDIANS);
        let (found, _) = vector::index_of(&vault.guardians, &guardian);
        assert!(!found, E_ALREADY_GUARDIAN);
        vector::push_back(&mut vault.guardians, guardian);
        event::emit(GuardianAdded { patient: vault.owner, guardian, timestamp: tx_context::epoch(ctx) });
    }

    /// Any guardian initiates recovery — specifies the replacement owner address
    public fun initiate_recovery(
        vault: &mut EarningsVault,
        new_owner: address,
        ctx: &mut TxContext,
    ) {
        let caller = tx_context::sender(ctx);
        let (is_guardian, _) = vector::index_of(&vault.guardians, &caller);
        assert!(is_guardian, E_NOT_GUARDIAN);
        let now = tx_context::epoch(ctx);
        // destroy any previous recovery request before creating a new one
        if (option::is_some(&vault.active_recovery)) {
            let old = option::extract(&mut vault.active_recovery);
            let RecoveryRequest { new_owner: _, initiated_at: _, confirmations: _, guardians: old_table, is_complete: _ } = old;
            table::destroy_empty(old_table);
        };
        let mut guardian_table: Table<address, Guardian> = table::new(ctx);
        table::add(&mut guardian_table, caller, Guardian { guardian_address: caller, confirmed_at: option::some(now) });
        // use option::fill instead of direct assignment — avoids drop requirement on RecoveryRequest
        option::fill(&mut vault.active_recovery, RecoveryRequest {
            new_owner,
            initiated_at: now,
            confirmations: 1,
            guardians: guardian_table,
            is_complete: false,
        });
        event::emit(RecoveryInitiated { patient: vault.owner, new_owner, timestamp: now });
    }

    /// Additional guardians confirm — 2 of 3 unlocks execute_recovery
    public fun confirm_recovery(vault: &mut EarningsVault, ctx: &mut TxContext) {
        let caller = tx_context::sender(ctx);
        let (is_guardian, _) = vector::index_of(&vault.guardians, &caller);
        assert!(is_guardian, E_NOT_GUARDIAN);
        assert!(option::is_some(&vault.active_recovery), E_RECOVERY_NOT_READY);
        let now = tx_context::epoch(ctx);
        let recovery = option::borrow_mut(&mut vault.active_recovery);
        assert!(!recovery.is_complete, E_RECOVERY_NOT_READY);
        assert!(now <= recovery.initiated_at + RECOVERY_WINDOW_EPOCHS, E_RECOVERY_NOT_READY);
        if (!table::contains(&recovery.guardians, caller)) {
            table::add(&mut recovery.guardians, caller, Guardian {
                guardian_address: caller,
                confirmed_at: option::some(now),
            });
            recovery.confirmations = recovery.confirmations + 1;
        };
        event::emit(RecoveryConfirmed {
            patient: vault.owner, guardian: caller,
            confirmations: recovery.confirmations, timestamp: now,
        });
    }

    /// Once threshold met, execute transfers ownership to new address
    public fun execute_recovery(vault: &mut EarningsVault, ctx: &mut TxContext) {
        assert!(option::is_some(&vault.active_recovery), E_RECOVERY_NOT_READY);
        let recovery = option::borrow(&vault.active_recovery);
        assert!(recovery.confirmations >= RECOVERY_THRESHOLD, E_RECOVERY_NOT_READY);
        assert!(!recovery.is_complete, E_RECOVERY_NOT_READY);
        let old_owner = vault.owner;
        let new_owner = recovery.new_owner;
        vault.owner = new_owner;
        option::borrow_mut(&mut vault.active_recovery).is_complete = true;
        event::emit(RecoveryCompleted { old_owner, new_owner, timestamp: tx_context::epoch(ctx) });
    }

    // ─── Read functions ───────────────────────────────────────────────────────

    public fun get_pending_balance(vault: &EarningsVault): u64    { balance::value(&vault.pending_mist) }
    public fun get_lifetime_earned(vault: &EarningsVault): u64    { vault.lifetime_earned_mist }
    public fun get_lifetime_withdrawn(vault: &EarningsVault): u64 { vault.lifetime_withdrawn_mist }
    public fun get_guardian_count(vault: &EarningsVault): u64     { vector::length(&vault.guardians) as u64 }
}
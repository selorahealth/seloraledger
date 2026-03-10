module selora::consent_ledger {
    use iota::event;
    use iota::table::{Self, Table};
    use std::string::String;

    const E_NOT_PATIENT:    u64 = 2001;
    const E_GRANT_NOT_FOUND: u64 = 2002;
    const E_GRANT_EXPIRED:  u64 = 2003;
    const E_ALREADY_REVOKED: u64 = 2004;

    // Scope levels — referenced by hospital portal and backend
    const SCOPE_EMERGENCY: u8 = 1; // allergies + blood type only, no PIN needed
    const SCOPE_FULL:      u8 = 2; // all records for grant duration
    const SCOPE_SPECIFIC:  u8 = 3; // patient-defined subset

    public struct ConsentGrant has store, drop {
        grant_id:     String,
        patient:      address,
        grantee_id:   String,
        grantee_type: String,
        scope:        u8,
        granted_at:   u64,
        expires_at:   u64,
        is_revoked:   bool,
        revoked_at:   Option<u64>,
        access_count: u64,
    }

    public struct ConsentRegistry has key {
        id:            UID,
        owner:         address,
        grants:        Table<String, ConsentGrant>,
        total_grants:  u64,
        active_grants: u64,
    }

    public struct AccessGranted has copy, drop {
        patient:      address,
        grant_id:     String,
        grantee_id:   String,
        grantee_type: String,
        scope:        u8,
        expires_at:   u64,
        timestamp:    u64,
    }

    public struct AccessRevoked has copy, drop {
        patient:    address,
        grant_id:   String,
        grantee_id: String,
        timestamp:  u64,
    }

    public struct AccessUsed has copy, drop {
        patient:    address,
        grant_id:   String,
        grantee_id: String,
        scope:      u8,
        timestamp:  u64,
    }

    public fun create_registry(ctx: &mut TxContext): ConsentRegistry {
        ConsentRegistry {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            grants: table::new(ctx),
            total_grants: 0,
            active_grants: 0,
        }
    }

    public fun grant_access(
        registry: &mut ConsentRegistry,
        grant_id: String,
        grantee_id: String,
        grantee_type: String,
        scope: u8,
        duration_seconds: u64,
        ctx: &mut TxContext,
    ) {
        assert!(registry.owner == tx_context::sender(ctx), E_NOT_PATIENT);
        let now = tx_context::epoch(ctx);
        let grant = ConsentGrant {
            grant_id,
            patient: registry.owner,
            grantee_id,
            grantee_type,
            scope,
            granted_at: now,
            expires_at: now + duration_seconds,
            is_revoked: false,
            revoked_at: option::none(),
            access_count: 0,
        };
        table::add(&mut registry.grants, grant_id, grant);
        registry.total_grants  = registry.total_grants  + 1;
        registry.active_grants = registry.active_grants + 1;
        event::emit(AccessGranted {
            patient: registry.owner, grant_id, grantee_id, grantee_type,
            scope, expires_at: now + duration_seconds, timestamp: now,
        });
    }

    public fun revoke_access(
        registry: &mut ConsentRegistry,
        grant_id: String,
        ctx: &mut TxContext,
    ) {
        assert!(registry.owner == tx_context::sender(ctx), E_NOT_PATIENT);
        assert!(table::contains(&registry.grants, grant_id), E_GRANT_NOT_FOUND);
        let grant = table::borrow_mut(&mut registry.grants, grant_id);
        assert!(!grant.is_revoked, E_ALREADY_REVOKED);
        let now = tx_context::epoch(ctx);
        grant.is_revoked  = true;
        grant.revoked_at  = option::some(now);
        registry.active_grants = registry.active_grants - 1;
        event::emit(AccessRevoked {
            patient: registry.owner,
            grant_id,
            grantee_id: grant.grantee_id,
            timestamp: now,
        });
    }

    public fun record_access_use(
        registry: &mut ConsentRegistry,
        grant_id: String,
        ctx: &mut TxContext,
    ) {
        assert!(table::contains(&registry.grants, grant_id), E_GRANT_NOT_FOUND);
        let grant = table::borrow_mut(&mut registry.grants, grant_id);
        let now = tx_context::epoch(ctx);
        assert!(!grant.is_revoked, E_ALREADY_REVOKED);
        assert!(grant.expires_at > now, E_GRANT_EXPIRED);
        grant.access_count = grant.access_count + 1;
        event::emit(AccessUsed {
            patient: registry.owner,
            grant_id,
            grantee_id: grant.grantee_id,
            scope: grant.scope,
            timestamp: now,
        });
    }

    public fun is_grant_valid(registry: &ConsentRegistry, grant_id: String, ctx: &TxContext): bool {
        if (!table::contains(&registry.grants, grant_id)) return false;
        let grant = table::borrow(&registry.grants, grant_id);
        let now = tx_context::epoch(ctx);
        !grant.is_revoked && grant.expires_at > now
    }
}
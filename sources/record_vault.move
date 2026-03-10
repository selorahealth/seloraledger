module selora::record_vault {
    use iota::event;
    use iota::table::{Self, Table};
    use std::string::{Self, String};

    const E_NOT_OWNER: u64     = 1001;
    const E_RECORD_NOT_FOUND: u64 = 1002;
    const E_ALREADY_DELETED: u64  = 1003;

    public struct RecordEntry has store, drop {
        record_id:      String,
        content_hash:   String,
        storj_cid:      String,
        record_type:    String,
        created_at:     u64,
        institution_id: Option<String>,
        is_deleted:     bool,
        deleted_at:     Option<u64>,
    }

    public struct PatientVault has key {
        id:              UID,
        owner:           address,
        records:         Table<String, RecordEntry>,
        record_count:    u64,
        deletion_count:  u64,
    }

    public struct RecordAdded has copy, drop {
        patient:      address,
        record_id:    String,
        record_type:  String,
        content_hash: String,
        timestamp:    u64,
    }

    public struct RecordDeleted has copy, drop {
        patient:   address,
        record_id: String,
        timestamp: u64,
    }

    public struct RecordVerified has copy, drop {
        patient:        address,
        record_id:      String,
        institution_id: String,
        timestamp:      u64,
    }

    public fun create_vault(ctx: &mut TxContext): PatientVault {
        PatientVault {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            records: table::new(ctx),
            record_count: 0,
            deletion_count: 0,
        }
    }

    public fun add_record(
        vault: &mut PatientVault,
        record_id: String,
        content_hash: String,
        storj_cid: String,
        record_type: String,
        ctx: &mut TxContext,
    ) {
        assert!(vault.owner == tx_context::sender(ctx), E_NOT_OWNER);
        let timestamp = tx_context::epoch(ctx);
        let entry = RecordEntry {
            record_id,
            content_hash,
            storj_cid,
            record_type,
            created_at: timestamp,
            institution_id: option::none(),
            is_deleted: false,
            deleted_at: option::none(),
        };
        table::add(&mut vault.records, record_id, entry);
        vault.record_count = vault.record_count + 1;
        event::emit(RecordAdded { patient: vault.owner, record_id, record_type, content_hash, timestamp });
    }

    public fun delete_record(
        vault: &mut PatientVault,
        record_id: String,
        ctx: &mut TxContext,
    ) {
        assert!(vault.owner == tx_context::sender(ctx), E_NOT_OWNER);
        assert!(table::contains(&vault.records, record_id), E_RECORD_NOT_FOUND);
        let entry = table::borrow_mut(&mut vault.records, record_id);
        assert!(!entry.is_deleted, E_ALREADY_DELETED);
        let timestamp = tx_context::epoch(ctx);
        entry.is_deleted = true;
        entry.deleted_at = option::some(timestamp);
        // Mark CID as deleted — backend listens for this event to purge from Storj
        entry.storj_cid = string::utf8(b"DELETED");
        vault.deletion_count = vault.deletion_count + 1;
        event::emit(RecordDeleted { patient: vault.owner, record_id, timestamp });
    }

    public fun verify_record(
        vault: &mut PatientVault,
        record_id: String,
        institution_id: String,
        ctx: &mut TxContext,
    ) {
        assert!(table::contains(&vault.records, record_id), E_RECORD_NOT_FOUND);
        let entry = table::borrow_mut(&mut vault.records, record_id);
        assert!(!entry.is_deleted, E_ALREADY_DELETED);
        entry.institution_id = option::some(institution_id);
        let timestamp = tx_context::epoch(ctx);
        event::emit(RecordVerified { patient: vault.owner, record_id, institution_id, timestamp });
    }

    public fun get_record_count(vault: &PatientVault): u64 {
        vault.record_count - vault.deletion_count
    }

    public fun is_record_deleted(vault: &PatientVault, record_id: String): bool {
        if (!table::contains(&vault.records, record_id)) return true;
        table::borrow(&vault.records, record_id).is_deleted
    }

    public fun verify_record_hash(vault: &PatientVault, record_id: String, expected_hash: String): bool {
        if (!table::contains(&vault.records, record_id)) return false;
        let entry = table::borrow(&vault.records, record_id);
        entry.content_hash == expected_hash && !entry.is_deleted
    }
}
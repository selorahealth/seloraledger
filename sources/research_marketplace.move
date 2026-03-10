module selora::research_marketplace {
    use iota::event;
    use iota::balance::{Self, Balance};
    use iota::iota::IOTA;
    use iota::coin::{Self, Coin};
    use iota::table::{Self, Table};
    use std::string::{Self, String};

    const E_NOT_ADMIN:        u64 = 6001;
    const E_NOT_RESEARCHER:   u64 = 6002;
    const E_STUDY_NOT_FOUND:  u64 = 6003;
    const E_STUDY_NOT_ACTIVE: u64 = 6004;
    const E_INSUFFICIENT_FUNDS: u64 = 6005;
    const E_IRB_EXPIRED:      u64 = 6006;
    const E_ALREADY_PARTICIPANT: u64 = 6007;
    const E_NOT_PARTICIPANT:  u64 = 6008;

    // Immutable after deployment - split cannot be changed by anyone
    // On every research payment:
    //   30% goes to Selora (platform fee, taken first off the top)
    //   Of the remaining 70%:
    //     70% goes to the patient pool  = 49% of total
    //     30% goes to the hospital pool = 21% of total
    const SELORA_SHARE_BPS:    u64 = 3000;  // 30.00% - Selora platform fee
    const PATIENT_SHARE_BPS:   u64 = 4900;  // 49.00% - patient pool
    const HOSPITAL_SHARE_BPS:  u64 = 2100;  // 21.00% - hospital pool
    const BPS_DENOMINATOR:     u64 = 10000;
    const MIN_MONTHLY_RATE_MIST: u64 = 1_000_000; // minimum pay per patient/month

    public struct Researcher has store {
        researcher_id:  String,
        institution:    String,
        irb_expiry:     u64,
        is_verified:    bool,
        total_spent:    u64,
        active_studies: u64,
    }

    public struct Study has store {
        study_id:            String,
        researcher_id:       String,
        title:               String,
        description:         String,
        monthly_rate_mist:   u64,
        max_participants:    u64,
        active_participants: u64,
        required_data_types: vector<String>,
        is_active:           bool,
        created_at:          u64,
        irb_expiry:          u64,
        patient_pool_mist:   Balance<IOTA>, // 49% - patient earnings pool
        hospital_pool_mist:  Balance<IOTA>, // 21% - hospital earnings pool
        selora_fees_mist:    Balance<IOTA>, // 30% - Selora platform fee
        total_funded_mist:   u64,
        total_distributed_mist: u64,
    }

    public struct Marketplace has key {
        id:                    UID,
        admin:                 address,
        researchers:           Table<String, Researcher>,
        studies:               Table<String, Study>,
        participants:          Table<String, vector<address>>,
        total_studies:         u64,
        total_distributed_mist: u64,
    }

    public struct ResearcherVerified has copy, drop {
        researcher_id: String,
        institution:   String,
        timestamp:     u64,
    }

    public struct StudyCreated has copy, drop {
        study_id:          String,
        researcher_id:     String,
        monthly_rate_mist: u64,
        max_participants:  u64,
        timestamp:         u64,
    }

    public struct StudyFunded has copy, drop {
        study_id:            String,
        total_mist:          u64,
        selora_fee_mist:     u64,
        patient_pool_mist:   u64,
        hospital_pool_mist:  u64,
        timestamp:           u64,
    }

    public struct ParticipantJoined has copy, drop {
        study_id:  String,
        patient:   address,
        timestamp: u64,
    }

    public struct ParticipantLeft has copy, drop {
        study_id:  String,
        patient:   address,
        timestamp: u64,
    }

    public struct EarningsDistributed has copy, drop {
        study_id:    String,
        patient:     address,
        amount_mist: u64,
        timestamp:   u64,
    }

    public struct StudyPaused has copy, drop {
        study_id:  String,
        reason:    String,
        timestamp: u64,
    }

    public fun create_marketplace(ctx: &mut TxContext): Marketplace {
        Marketplace {
            id: object::new(ctx),
            admin: tx_context::sender(ctx),
            researchers: table::new(ctx),
            studies: table::new(ctx),
            participants: table::new(ctx),
            total_studies: 0,
            total_distributed_mist: 0,
        }
    }

    public fun verify_researcher(
        mp: &mut Marketplace,
        researcher_id: String,
        institution: String,
        irb_expiry: u64,
        ctx: &mut TxContext,
    ) {
        assert!(mp.admin == tx_context::sender(ctx), E_NOT_ADMIN);
        let researcher = Researcher {
            researcher_id, institution, irb_expiry,
            is_verified: true, total_spent: 0, active_studies: 0,
        };
        table::add(&mut mp.researchers, researcher_id, researcher);
        event::emit(ResearcherVerified { researcher_id, institution, timestamp: tx_context::epoch(ctx) });
    }

    public fun create_study(
        mp: &mut Marketplace,
        study_id: String,
        researcher_id: String,
        title: String,
        description: String,
        monthly_rate_mist: u64,
        max_participants: u64,
        required_data_types: vector<String>,
        ctx: &mut TxContext,
    ) {
        assert!(table::contains(&mp.researchers, researcher_id), E_NOT_RESEARCHER);
        let researcher = table::borrow(&mp.researchers, researcher_id);
        assert!(researcher.is_verified, E_NOT_RESEARCHER);
        assert!(researcher.irb_expiry > tx_context::epoch(ctx), E_IRB_EXPIRED);
        assert!(monthly_rate_mist >= MIN_MONTHLY_RATE_MIST, E_INSUFFICIENT_FUNDS);

        let study = Study {
            study_id, researcher_id, title, description,
            monthly_rate_mist, max_participants,
            active_participants: 0,
            required_data_types,
            is_active: false,
            created_at: tx_context::epoch(ctx),
            irb_expiry: researcher.irb_expiry,
            patient_pool_mist:  balance::zero(),
            hospital_pool_mist: balance::zero(),
            selora_fees_mist:   balance::zero(),
            total_funded_mist: 0,
            total_distributed_mist: 0,
        };
        table::add(&mut mp.studies, study_id, study);
        table::add(&mut mp.participants, study_id, vector::empty());
        mp.total_studies = mp.total_studies + 1;

        event::emit(StudyCreated {
            study_id, researcher_id, monthly_rate_mist, max_participants,
            timestamp: tx_context::epoch(ctx),
        });
    }

    /// Researcher funds the study — 75/25 split is atomic and enforced here
    public fun fund_study(
        mp: &mut Marketplace,
        study_id: String,
        payment: Coin<IOTA>,
        ctx: &mut TxContext,
    ) {
        assert!(table::contains(&mp.studies, study_id), E_STUDY_NOT_FOUND);
        let study = table::borrow_mut(&mut mp.studies, study_id);
        assert!(study.irb_expiry > tx_context::epoch(ctx), E_IRB_EXPIRED);
        let total = coin::value(&payment);
        assert!(total > 0, E_INSUFFICIENT_FUNDS);

        // Hard-coded split - immutable, enforced on-chain
        // 30% Selora | 49% patients | 21% hospitals
        let selora_share   = (total * SELORA_SHARE_BPS)   / BPS_DENOMINATOR;
        let patient_share  = (total * PATIENT_SHARE_BPS)  / BPS_DENOMINATOR;
        // hospital gets the remainder to avoid rounding dust
        let hospital_share = total - selora_share - patient_share;

        let mut bal = coin::into_balance(payment);
        // 1. Take Selora cut first
        let selora_cut   = balance::split(&mut bal, selora_share);
        // 2. Take hospital cut second
        let hospital_cut = balance::split(&mut bal, hospital_share);
        // 3. Everything remaining goes to patients
        balance::join(&mut study.selora_fees_mist,   selora_cut);
        balance::join(&mut study.hospital_pool_mist, hospital_cut);
        balance::join(&mut study.patient_pool_mist,  bal);

        study.total_funded_mist = study.total_funded_mist + total;
        study.is_active = true;

        event::emit(StudyFunded {
            study_id, total_mist: total,
            selora_fee_mist:    selora_share,
            patient_pool_mist:  patient_share,
            hospital_pool_mist: hospital_share,
            timestamp: tx_context::epoch(ctx),
        });
    }

    public fun join_study(mp: &mut Marketplace, study_id: String, ctx: &mut TxContext) {
        assert!(table::contains(&mp.studies, study_id), E_STUDY_NOT_FOUND);
        assert!(table::borrow(&mp.studies, study_id).is_active, E_STUDY_NOT_ACTIVE);
        let patient = tx_context::sender(ctx);
        let participants = table::borrow_mut(&mut mp.participants, study_id);
        let (found, _) = vector::index_of(participants, &patient);
        assert!(!found, E_ALREADY_PARTICIPANT);
        vector::push_back(participants, patient);
        table::borrow_mut(&mut mp.studies, study_id).active_participants =
            table::borrow(&mp.studies, study_id).active_participants + 1;
        event::emit(ParticipantJoined { study_id, patient, timestamp: tx_context::epoch(ctx) });
    }

    public fun leave_study(mp: &mut Marketplace, study_id: String, ctx: &mut TxContext) {
        let patient = tx_context::sender(ctx);
        let participants = table::borrow_mut(&mut mp.participants, study_id);
        let (found, idx) = vector::index_of(participants, &patient);
        assert!(found, E_NOT_PARTICIPANT);
        vector::remove(participants, idx);
        table::borrow_mut(&mut mp.studies, study_id).active_participants =
            table::borrow(&mp.studies, study_id).active_participants - 1;
        event::emit(ParticipantLeft { study_id, patient, timestamp: tx_context::epoch(ctx) });
    }

    /// Backend calls this monthly per participant — returns coin for earnings_vault::deposit
    public fun distribute_to_participant(
        mp: &mut Marketplace,
        study_id: String,
        patient: address,
        ctx: &mut TxContext,
    ): Coin<IOTA> {
        assert!(mp.admin == tx_context::sender(ctx), E_NOT_ADMIN);
        let study = table::borrow_mut(&mut mp.studies, study_id);
        assert!(study.is_active, E_STUDY_NOT_ACTIVE);
        let amount = study.monthly_rate_mist;
        assert!(balance::value(&study.patient_pool_mist) >= amount, E_INSUFFICIENT_FUNDS);
        study.total_distributed_mist = study.total_distributed_mist + amount;
        mp.total_distributed_mist    = mp.total_distributed_mist + amount;
        event::emit(EarningsDistributed { study_id, patient, amount_mist: amount, timestamp: tx_context::epoch(ctx) });
        coin::from_balance(balance::split(&mut study.patient_pool_mist, amount), ctx)
    }

    /// Selora withdraws its 25% fee to treasury
    public fun withdraw_selora_fees(
        mp: &mut Marketplace,
        study_id: String,
        ctx: &mut TxContext,
    ): Coin<IOTA> {
        assert!(mp.admin == tx_context::sender(ctx), E_NOT_ADMIN);
        let study = table::borrow_mut(&mut mp.studies, study_id);
        let amount = balance::value(&study.selora_fees_mist);
        assert!(amount > 0, E_INSUFFICIENT_FUNDS);
        coin::from_balance(balance::split(&mut study.selora_fees_mist, amount), ctx)
    }

    /// Auto-pause any study whose IRB has lapsed
    public fun admin_pause_expired_irb(
        mp: &mut Marketplace,
        study_id: String,
        ctx: &mut TxContext,
    ) {
        assert!(mp.admin == tx_context::sender(ctx), E_NOT_ADMIN);
        let study = table::borrow_mut(&mut mp.studies, study_id);
        assert!(study.irb_expiry <= tx_context::epoch(ctx), E_STUDY_NOT_FOUND);
        study.is_active = false;
        event::emit(StudyPaused {
            study_id,
            reason: string::utf8(b"IRB_EXPIRED"),
            timestamp: tx_context::epoch(ctx),
        });
    }

    /// Returns (selora_share, patient_share, hospital_share) for any given amount
    public fun get_split_preview(amount_mist: u64): (u64, u64, u64) {
        let selora   = (amount_mist * SELORA_SHARE_BPS)  / BPS_DENOMINATOR;
        let patient  = (amount_mist * PATIENT_SHARE_BPS) / BPS_DENOMINATOR;
        let hospital = amount_mist - selora - patient;
        (selora, patient, hospital)
    }

    /// Hospital withdraws its 21% pool — callable by admin on behalf of verified hospital
    public fun withdraw_hospital_fees(
        mp: &mut Marketplace,
        study_id: String,
        ctx: &mut TxContext,
    ): Coin<IOTA> {
        assert!(mp.admin == tx_context::sender(ctx), E_NOT_ADMIN);
        let study = table::borrow_mut(&mut mp.studies, study_id);
        let amount = balance::value(&study.hospital_pool_mist);
        assert!(amount > 0, E_INSUFFICIENT_FUNDS);
        coin::from_balance(balance::split(&mut study.hospital_pool_mist, amount), ctx)
    }
}
# services/verification

Offchain verifier service. **Not started. Planned for Phase 3.**

It receives encrypted evidence bundles from providers, performs review, and submits `approveProof`, `rejectProof` and `resolveDispute` transactions. Evidence never leaves this boundary. Only salted commitments go onchain (see docs/contract-spec.md §5).

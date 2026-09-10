# Sample inventories

`SourceInventory.Sample.csv` and `TargetInventory.Sample.csv` use the normalized schema emitted by the packaged collectors. They intentionally include:

- Duplicate SMTP proxy values in the source and target.
- A duplicate `sAMAccountName` in the target.
- A many-source-to-one-target claim.
- One source object whose UPN and proxy address resolve to different target objects.
- A valid immutable-ID match across `ConsistencyGuidBase64` and `OnPremisesImmutableId`.
- A row with no usable anchors.
- Malformed UPN, primary SMTP, and proxy-address values.

The values are synthetic and do not represent real tenants, domains, accounts, or identifiers.

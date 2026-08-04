# Security policy

## Supported version

Security fixes are applied to the latest code on the default branch. Older tags do
not receive a separate support window before a policy is announced here.

## Report a vulnerability

Please do not open a public issue for a suspected vulnerability. Use the repository's
[private vulnerability reporting form](https://github.com/romankhadka/worldloom/security/advisories/new)
and include:

- the affected route, component, or commit;
- a minimal reproduction;
- the impact you believe is possible; and
- any suggested mitigation, if you have one.

Do not access other people's data, degrade the public service, persist test payloads,
or run automated high-volume probes. The maintainers will acknowledge a complete
report as soon as practical, investigate it, and coordinate disclosure after a fix is
available. Please allow a reasonable remediation period before publishing details.

## Relevant boundaries

Worldloom accepts no accounts, free-form text, uploads, or arbitrary URLs. Visitor
gestures are server allow-listed and rate-limited. The application stores normalized
public feed facts and anonymous gestures but never stores visitor identity or IP data
with those events. More detail is available in [docs/privacy.md](docs/privacy.md) and
[ARCHITECTURE.md](ARCHITECTURE.md).

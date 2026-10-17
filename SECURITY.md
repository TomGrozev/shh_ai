# Security Policy

ShhAi sits between client applications and LLM providers and handles personal
data, so we take vulnerability reports seriously and appreciate responsible
disclosure.

## Reporting a vulnerability

**Do not open a public issue for a security problem.** A public report exposes
users before a fix is available.

Report privately through GitHub's
[private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability):

1. Go to the repository's **Security** tab.
2. Choose **Advisories** → **Report a vulnerability**.
3. Describe the issue, the affected version, and steps to reproduce.

If the form is unavailable, contact the maintainer directly rather than posting
publicly.

Please include, as far as you can:

- The affected component or endpoint.
- A minimal reproduction or proof of concept.
- The impact you believe it has (e.g. PII leakage to a provider, auth bypass).
- Any suggested remediation.

## What to expect

- **Acknowledgement** of your report as soon as possible.
- An assessment and a fix timeline shared with you.
- Credit in the published advisory, unless you prefer to stay anonymous.

Please give us a reasonable window to release a fix before any public
disclosure.

## Supported versions

ShhAi is pre-1.0. Security fixes land on `master` and are released in the next
`0.1.x` version. Only the latest release is supported.

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Scope

In scope: the proxy's request handling, PII detection and restoration, the
inbound API-key gate, provider credential handling, and the audit store.

Out of scope: vulnerabilities in third-party LLM providers, and misconfiguration
of an operator's own reverse proxy or network (TLS terminates at the operator's
proxy, not in ShhAi).

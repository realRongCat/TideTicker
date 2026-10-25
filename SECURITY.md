# Security policy

## Supported versions

Security fixes are made on the latest source revision. Until a signed and
notarized binary release exists, build TideTicker from source and review the
commit you are running.

## Reporting a vulnerability

Do not post credentials, private network details, local configuration, or a
working exploit in a public issue. Use GitHub's private vulnerability reporting
feature when it is enabled for the repository. Otherwise, open a public issue
that contains only a brief impact summary and asks the maintainer for a private
contact channel.

Include the affected revision, macOS version, reproduction conditions, and the
smallest redacted diagnostic output needed to understand the issue.

## Scope

TideTicker consumes public market data and sends local notifications. It does
not hold exchange credentials, manage funds, or execute trades. Price alerts
are observational and must not be treated as exchange-grade risk controls.


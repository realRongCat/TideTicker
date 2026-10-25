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

The optional Kindle display exposes a read-only HTTP endpoint to the local
network. It is disabled by default and protected by a random path token, but it
does not provide TLS or user authentication. Anyone who can reach the Mac and
obtain the full URL can read the displayed market data and latest pending-alert
summary. Use it only on a trusted network, reset the address if it is disclosed,
and disable the feature when it is not needed. Internet-facing deployment,
port forwarding, remote configuration, and write access are outside the
supported security scope.


# Privacy

TideTicker does not require an account, API key, wallet, or trading permission.
It does not place orders and does not include analytics or telemetry.

The application stores its watchlist, display preferences, network mode, and
price-alert rules locally on the Mac. It uses macOS notification and login-item
facilities only when the user enables them.

To provide market data, TideTicker connects to public endpoints operated by
the selected exchange: OKX, Binance, or Bybit. In physical-direct mode it also
uses Cloudflare's public DNS-over-HTTPS endpoint to resolve the exchange's
official hostname. These operators receive the network information normally
exposed by an HTTPS request, such as the public IP address.

TideTicker does not transmit the local watchlist or alert thresholds to a
TideTicker server. Exchange requests necessarily identify the requested public
instrument. System notifications are delivered by macOS.

When automatic update checks are enabled, or when the user manually checks for
updates, TideTicker requests the latest stable release metadata from GitHub's
public API. The request includes the installed TideTicker version in its
standard HTTP User-Agent. It does not include the watchlist, alert thresholds,
exchange selection, or diagnostics. GitHub receives the network information
normally exposed by an HTTPS request. Automatic checks can be disabled from
the application menu; manual checks remain available.

The optional Kindle display is disabled by default. When the user enables it,
TideTicker starts a read-only HTTP service on the Mac's local network and shows
a URL containing a random access token. A device with that URL can read the
current watchlist quotes, market-status fields, supplementary market data, and
the latest pending alert while TideTicker is running. The service does not
accept configuration changes and does not relay requests to a TideTicker
server. Local HTTP traffic is not encrypted, so the feature should only be
enabled on a trusted network. Disabling the feature or quitting TideTicker
stops the service; resetting the address invalidates the previous token.

Questions about this policy can be raised through the repository's public
issue tracker without including private configuration, alert thresholds, IP
addresses, proxy details, or diagnostic logs.


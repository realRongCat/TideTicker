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

Questions about this policy can be raised through the repository's public
issue tracker without including private configuration, alert thresholds, IP
addresses, proxy details, or diagnostic logs.


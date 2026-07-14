{
  echo 'CARGO_HOME=${{ runner.temp }}/cargo-home/dns-nats-subscriber'
  echo 'RUSTUP_HOME=${{ runner.temp }}/rustup-home/dns-nats-subscriber'
} >> "$GITHUB_ENV"

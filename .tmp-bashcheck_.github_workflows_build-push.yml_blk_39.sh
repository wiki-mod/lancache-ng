{
  echo 'CARGO_HOME=${{ runner.temp }}/cargo-home/ui'
  echo 'RUSTUP_HOME=${{ runner.temp }}/rustup-home/ui'
} >> "$GITHUB_ENV"

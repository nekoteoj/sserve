# sserve

Ruby 4.0+ CLI (`required_ruby_version` in `sserve.gemspec`, `.ruby-version` is `4.0.7`). Run everything through Bundler.

```bash
bundle exec rspec
bundle exec rspec spec/sserve/app_spec.rb
bundle exec exe/sserve --help
```

`rake` is the same suite. There is no lint or typecheck step.

## Boundaries

- `CLI` parses argv and builds a frozen `Config`. It must not start iodine itself; specs inject a server double.
- `Auth` and `Files` return decisions. They do not build Rack responses.
- `App` is the only Roda/Rack adapter. `Server` is the only file that requires iodine.
- `App.build` subclasses `Roda`, loads sessions/CSRF only when a password is set, then `freeze`s. Do not write class instance variables after that.

## Do not "optimize" static files

Published iodine is `~> 0.7.60`. Do not follow the GitHub master README's `~> 0.8` or `Iodine.listen(..., public:)`.

The C static handler answers `GET`/`HEAD` before Ruby. Passing `public:` skips the password, the configured index, and the listing switch. Serve files with `Rack::Files` from a path `Files::Catalog` already accepted. Keep `Iodine.workers = 1`. Pass the port as a string.

Specs call `App.build` with `rack-test`. They must not boot iodine or bind a port.

## Auth and views

- Session values are JSON. Use string keys (`session["authenticated"]`). Symbol keys do not survive the cookie.
- `route_csrf` requires a path-specific token: `<%== csrf_tag("/_sserve/login") %>`. A bare `csrf_tag` fails. `<%==` is required because the render plugin escapes.
- Generated pages live in `lib/sserve/views`. CSS is read once into `App::STYLESHEET` at load. `/_sserve` is reserved and is not looked up in the serve root.
- Do not put a restrictive CSP on files served from the user's directory. That header is only for pages this app renders.

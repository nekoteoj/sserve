# sserve

A small command-line server for a static directory. It is a Roda application running on iodine, with an optional shared password and optional directory listings.

Requires Ruby 4.0 or newer.

## Install

```bash
bundle install
bundle exec exe/sserve --help
```

## Usage

```bash
sserve [DIRECTORY] [options]
```

```bash
sserve ./public
sserve --directory ./public --port 9090 --listings
sserve --bind 127.0.0.1 --password s3cret
SSERVE_PASSWORD=s3cret sserve --password-env SSERVE_PASSWORD
```

| Flag | Default | |
|---|---|---|
| `-d, --directory` | `.` | Directory to serve. A positional argument does the same. |
| `-b, --bind` | `127.0.0.1` | Bind address. |
| `-p, --port` | `8080` | Port. |
| `--prefix` | none | Browser mount path. sserve strips it once. The proxy must forward it unchanged. |
| `-i, --index` | `index.html` | Filename served for a directory. Must be a single path segment. |
| `-P, --password` | none | Shared password. Omit it and the directory is public. |
| `--password-env` | none | Read the password from an environment variable instead of the command line. |
| `-l, --listings` | off | List a directory when it has no index file. |

A password on the command line is visible to other users via `ps`. Prefer `--password-env`.

Binding a non-loopback address without a password prints a warning. The server still starts.

## Authentication

There is no username. When a password is set, a browser that is not signed in is redirected to `/_sserve/login` (under `--prefix`, when that is set). A correct password sets an encrypted cookie for 12 hours of idle time. Sign Out is on directory listings and on the generated error pages.

`/_sserve` is reserved by the server and is not looked up in the directory you are serving.

## Files

Paths are resolved with `realpath` and must stay inside the serve root. A symlink that points outside the root is not served. Dotfiles are hidden, including from listings.

An index file is served instead of a listing. A directory request that is not already the canonical trailing-slash URL is redirected to it, so relative links in that index keep working. With listings off and no index file, a directory request is forbidden. Other methods than `GET` and `HEAD` are rejected.

iodine's built-in static file handler is not used. That handler answers in C and never reaches Ruby, so it cannot apply the password, the index name, or the listing switch.

## Reverse proxy

Pass the browser mount path as `--prefix`. sserve removes that prefix from the request once, then adds it back to redirects, links, and the session cookie. The proxy must forward the prefix unchanged. If the proxy strips it too, a directory with the same name is served as the mount root: `/files/files/index.html` becomes `/index.html`.

```nginx
location /files/ {
  proxy_pass http://127.0.0.1:8080;
}
```

```bash
sserve --prefix /files --password-env SSERVE_PASSWORD
```

`location /files/` does not match a request for `/files` with no trailing slash. Redirect that to `/files/`, or use `location /files`. Do not rewrite `Location` with `proxy_redirect`; sserve already emits prefixed URLs.

## Development

```bash
bundle exec rspec
```

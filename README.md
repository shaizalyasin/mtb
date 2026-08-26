# mtb-demo

Official cBioPortal **6.4.4**, unmodified, with our MTB features injected as a
separately served JavaScript bundle — no fork, no patched frontend, no rebuilt
image.

This exists to answer one question: *can we stop maintaining a fork of
`cbioportal-frontend` and instead run our features against a stock,
version-pinned portal?*

**Yes.** It works, it is verified end to end below, and the cost is one short
per-upgrade check rather than a rebase.

## What is actually running

| Service | What it is |
| --- | --- |
| `cbioportal` | `cbioportal/cbioportal:6.4.4`, pulled from Docker Hub, unmodified |
| `cbioportal-database` | MySQL 8 with the official seed |
| `cbioportal-session` / `-database` | session service + Mongo, as upstream ships it |
| `mtb-tools` | nginx serving `mtb-tools.js` / `mtb-tools.css`, built from the sibling `mtb-clinical-tools` repo |

The only thing distinguishing this from a stock cBioPortal deployment:

- one mounted file, [`config/frontend.json`](config/frontend.json),
- one extra JVM argument, `--frontend.config=/mtb-config/frontend.json`,
- one extra container serving two static files.

Upgrading cBioPortal is editing `DOCKER_IMAGE_CBIOPORTAL` in [`.env`](.env) and
re-running. The features come along untouched because they were never in the
portal to begin with.

## Prerequisites

Docker, and **both repos checked out side by side**:

```
some-parent-dir/
  mtb-demo/            <- you are here
  mtb-clinical-tools/  <- the bundle, built as a compose step
```

The path is set by `MTB_TOOLS_CONTEXT` in [`.env`](.env) and defaults to
`../mtb-clinical-tools`. Point it elsewhere if you lay the checkouts out
differently.

## Running it

First run downloads ~65MB and takes several minutes, mostly
seeding the database.

```bash
./init.sh                      # schema (from the pinned image), seed DB, demo study
docker compose up -d --build   # brings up the portal and builds the bundle
./import-study.sh              # cBioPortal will not render with zero studies
```

Then open <http://localhost:8090/patient?studyId=lgg_ucsf_2014&caseId=P01> and
click **MTB Demo**.

The bundle is served separately at <http://localhost:8081/mtb-tools.js>.

## Verifying it

```bash
./verify.sh
```

Drives a real headless browser through every success criterion and prints a
pass/fail line each. No local Node or browser needed — it runs in a container.

```
PASS  Custom tab appears in the Patient View tab bar
PASS  Bundle loaded from :8081 and mountCallbackName resolved off window
PASS  Mutation count shows a pending state while the store is fetching
PASS  Mutation count went pending -> real number, and matches the REST API -- rendered 1272, API reports 1272
PASS  Study / patient / sample identifiers read from the live store -- study=lgg_ucsf_2014 patient=P01 samples=P01_Pri, P01_Rec
PASS  No duplicate content after switching tabs away and back 3x -- 1 panel before, 1 after
PASS  Remounted tab still reads the store -- mutations=1272; Tab mounted 4 times this page load.
PASS  No MTB-related console errors

8/8 checks passed
```

The third and fourth lines are the ones that matter. `verify.mjs` deliberately
holds the mutation response until *after* the tab has mounted, so the tab must
render `loading…` and then update to `1272` on its own — which only a live
subscription to the portal's store can do. A value captured at mount time would
be indistinguishable from a correct one without that stall.

`./debug.sh` dumps the same page's console, config, store state and DOM when
something needs investigating.

## The authentication overlay

The base demo runs with `authenticate=false` and no backend, because the mount
contract was the thing being proven. `docker-compose.auth.yml` layers on the
rest of the MTB-cBioPortal authentication path so the second question -- can a
mounted tab reach an authenticated backend? -- can be answered too.

```bash
docker compose -f docker-compose.yml -f docker-compose.auth.yml up -d --build
./verify-auth.sh
```

It adds Keycloak, an OpenResty proxy with `lua-resty-openidc`, and a small
stand-in for FhirSpark. Everything the browser touches -- portal, Keycloak,
bundle, backend -- is served from `http://localhost:8090`, which is the whole
reason no token handling is needed.

```
PASS  Portal, Keycloak and the bundle are all served from one origin
PASS  Unauthenticated GET to the MTB backend succeeds
PASS  Unauthenticated POST is refused with 401 + loginUrl, not a redirect to Keycloak
PASS  Tab mounted with the backend panel
PASS  Starts unauthenticated
PASS  The 401 opened the Keycloak login flow
PASS  After login the write succeeded -- Molecular Tumorboard (mtbuser)
PASS  Client roles reached the backend -- ["mtb_user"]
PASS  The session cookie rode along without the bundle asking for it
NOTE  cBioPortal session cookie: absent -- portal is running unauthenticated
PASS  The recommendation was persisted
PASS  The bundle never sent a credential of its own

11/11 checks passed
```

### What it establishes

**"No additional token handling" is true.** The bundle contains no
`Authorization` header, no `credentials` option and no token code. The browser
attaches the proxy's OIDC session cookie by itself because the request is
same-origin, and the proxy turns that into `X-USERLOGIN` / `X-USERROLES` headers
for the backend. The verification asserts this negatively: it watches every
request the page makes and fails if the page ever sends a credential.

**"No additional login handling" is false.** An unauthenticated write cannot
simply be issued and forgotten. The bundle has to recognise a 401, open the
login flow, and retry -- roughly forty lines in
[`AuthPanel.tsx`](../mtb-clinical-tools/src/AuthPanel.tsx). Any real MTB or
Follow-up tab needs the same, and it is worth designing once in the bundle
rather than per feature.

**It is not cBioPortal's session that authorises the write.** OpenResty runs its
own `resty-openidc` session against Keycloak, with its own cookie. FhirSpark
never sees OIDC at all; it trusts headers the proxy injects. cBioPortal's
session is used for something different -- `lua_login_config.lua` reads
`JSESSIONID` and calls `/api/studies` with it to determine study-level
permissions.

### What it does not establish

That last part is untested here. With `authenticate=false` the portal issues no
cookie at all, so there is no `JSESSIONID` to travel with the request and the
study-permission path cannot run. Closing that gap means wiring cBioPortal's own
Spring Security to the same Keycloak, which is a larger change than the mount
contract needed.

The backend is also a stand-in, not FhirSpark. That is deliberate: the auth
question is decided entirely in the proxy, and FhirSpark's own behaviour --
which is to trust the injected headers -- is reproduced exactly. What is not
covered is FhirSpark's data model.

### Design notes worth keeping

Three things here were not obvious and cost time:

**A redirect is the wrong answer to a `fetch`.** `resty-openidc`'s
`authenticate()` 302s to Keycloak when there is no session. For a page
navigation that is correct; for an XHR the browser follows it and the caller
gets Keycloak's HTML login page instead of a usable status. The config uses
`authenticate(opts, nil, "deny")` on the API path so callers get a 401 with a
`loginUrl` they can act on, and keeps the redirect flow only on `/mtb/login`,
which is opened as a top-level navigation.

**The IdP needs two addresses.** The browser is redirected to
`authorization_endpoint`, so that must be the public origin; the proxy calls
`token_endpoint` and `jwks_uri` itself, from inside the compose network. Letting
`resty-openidc` discover both from the public URL makes it use public addresses
for both, and its resolver is Docker's embedded DNS, which has no answer for
`localhost` -- so it fails with `localhost could not be resolved` while the
browser reaches the very same URL without trouble. The discovery document is
therefore supplied as a table with the two split apart.

**`lua-resty-session` 4.x needs OpenSSL 3.** It derives keys with HKDF via
`lua-resty-openssl`'s `kdf.new()`, which only exists when the linked OpenSSL
provides `EVP_KDF`. OpenResty 1.25 still bundles OpenSSL 1.1.1w, and the symptom
is a bare `attempt to call field 'new' (a nil value)` from inside the session
library with nothing pointing at OpenSSL. The proxy builds on OpenResty 1.27.

## Adding more studies

Studies are imported with cBioPortal's own `metaImport.py`, run inside the
portal container — the same tool the `MTB-cbioportal` deployment uses. Nothing
here is special to this repo.

**From the public DataHub** (what `init.sh` does):

```bash
curl -fL -o study/<id>.tar.gz "https://datahub.assets.cbioportal.org/<id>.tar.gz"
tar xzf study/<id>.tar.gz -C study && rm study/<id>.tar.gz
./import-study.sh <id>
```

**From a local directory** — a study that is not on the DataHub, or a public
study extended with institution-specific data:

```bash
./add-local-study.sh /path/to/study-dir
./import-study.sh <id>
```

`add-local-study.sh` copies the directory into `study/`, finds the level that
actually holds `meta_study.txt` (archives often unzip to `<name>/<name>/`),
strips macOS `__MACOSX` / `._*` cruft, and appends the trailing newline that
several `meta_*.txt` files are missing — the importer parses them line-wise and
silently ignores an unterminated last line.

### asclc_msk_2024 — the feature-testing study

The copy in `MTB-cbioportal/study/asclc_msk_2024` is the public MSK study
*extended with EQ-5D-5L timeline events*, which makes it the only study on hand
that can exercise PROMs. Stage and import it with:

```bash
./add-local-study.sh ../MTB-cbioportal/study/asclc_msk_2024
./import-study.sh asclc_msk_2024
```

It carries mutations, discrete CNA, structural variants, mRNA expression, rich
timeline data and EQ-5D-5L events, so it covers considerably more of the store
than `lgg_ucsf_2014`. Point the verification at it with:

```bash
VERIFY_STUDY_ID=asclc_msk_2024 VERIFY_PATIENT_ID=P-0012905 ./verify.sh
```

Twelve of its 31 patients have EQ-5D-5L data; `P-0012905` is one of them.

> **Fixed on import:** the source study's `data_timeline_eq5d5l.txt` header reads
> `<TAB> USUAL_ACTIVITY` with a leading space, so that attribute imports as
> `" USUAL_ACTIVITY"`. PROMs matches attribute keys by exact string equality, so
> the dimension would silently disappear from the charts. The copy under
> `study/` has the space removed — **the source in `MTB-cbioportal` still has
> it** and should be fixed there too.

> **Not committed.** `study/` is gitignored. `asclc_msk_2024` is licensed
> CC BY-NC-ND 4.0, the extended version is a derivative of it, and the
> provenance of the EQ-5D-5L values has not been established here. Decide
> deliberately before putting it in a public repository.

## Pushing this to GitHub

Two repos, pushed separately -- that separation is the point, not an
inconvenience:

```bash
# in mtb-clinical-tools/
git remote add origin git@github.com:<org>/mtb-clinical-tools.git
git push -u origin main

# in mtb-demo/
git remote add origin git@github.com:<org>/mtb-demo.git
git push -u origin main
```

Nothing needs to be built or published for a reviewer to try it -- they clone
both repos side by side and run the three commands under "Running it". The
bundle is built from source by compose, so there is no artifact to host and no
registry to configure.

### Continuous verification

[`.github/workflows/verify.yml`](.github/workflows/verify.yml) runs the whole
thing on every push: brings up the official image, injects the bundle by config
alone, and runs `verify.sh` in a real browser. Screenshots and logs are uploaded
as build artifacts, so a failure shows you the actual page rather than a stack
trace.

It checks out `<owner>/mtb-clinical-tools` at `main` by default. Override with
repository variables if yours is named or branched differently:

| Variable | Purpose |
| --- | --- |
| `MTB_TOOLS_REPO` | e.g. `my-org/mtb-tools` |
| `MTB_TOOLS_REF` | branch or tag of the bundle to test against |

### Testing a cBioPortal upgrade before committing to it

This is the part that replaces the fork rebase. Run the workflow manually
(**Actions -> verify -> Run workflow**) and give it a candidate image:

```
cbioportal/cbioportal:6.4.5
```

Green means the mount contract still holds and the upgrade is a one-line edit to
`.env`. Red names the exact criterion that broke, and
[`../mtb-clinical-tools/CONTRACT.md`](../mtb-clinical-tools/CONTRACT.md) says
where in the upstream source to look. Either way you learn it in minutes,
without touching a branch.

## How it works

cBioPortal's `custom_tabs` is JavaScript injection into the portal's own page,
not an iframe:

1. The backend reads `frontend.json` (via `--frontend.config`) and serves it to
   its own frontend through `/config_service` as `frontendConfigOverride`.
2. The frontend sees the entry in `serverConfig.custom_tabs` and adds a tab.
3. On first activation it appends `pathsToCSS` as `<link>`, loads `pathsToJs`
   as `<script>`, then looks up `mountCallbackName` on `window` and calls it as
   `(div, tab, url, store, autorun, isUnmount)`.

Same document, same origin — so the callback gets the portal's real MobX
`autorun` and its real `PatientViewPageStore`, and the tab is genuinely
reactive rather than a static render.

## Things that were not obvious

Each of these cost real time; they are recorded so the next upgrade doesn't.

**Config injection is pure runtime.** `custom_tabs` is a *backend* property
read from a mounted JSON file at startup. No frontend rebuild is involved, so
the "unmodified pre-built image" model holds fully — the rebuild fallback was
never needed.

**The `store` argument is `null` on the patient page.** The live path passes a
hardcoded `null`; the store is read from `window.patientViewPageStore` instead.
This is the most important finding here — see
[`../mtb-clinical-tools/CONTRACT.md`](../mtb-clinical-tools/CONTRACT.md).

**Tab ids are not free-form.** The id becomes a URL path segment and is
validated by the router. An unrecognised id blanks the entire patient view when
you click the tab. Details in `config/frontend.json`.

**No Content-Security-Policy.** The 6.4.4 image sets `X-Frame-Options`,
`X-Content-Type-Options` and friends, but no CSP — so serving the bundle from a
separate origin works, and the shared-proxy fallback is unnecessary. Worth
re-checking on upgrade; if a CSP ever appears, put the bundle behind the same
proxy as the portal.

**The official healthcheck's magic number is version-specific.** Upstream's
compose asserts `type_of_cancer` has exactly 853 rows; seed 2.14.5, which 6.4.4
wants, has 852. This repo uses a threshold instead.

**Seed and schema versions are coupled.** `init.sh` reads `DB_SCHEMA_VERSION`
out of the image's own `cgds.sql` and downloads the matching seed, so a tag bump
picks up the right seed by itself.

**`config/` is mounted as a directory, not as a single file.** Editors replace
files rather than rewriting them, and a single-file bind mount dies when its
inode changes — with a "no such file or directory" error naming a file that is
plainly there.

## Relationship to the other repos

- **`mtb-clinical-tools`** (sibling) — the bundle. Built here as a compose step
  via `MTB_TOOLS_CONTEXT`. Separate repo because it changes when our features
  change, while this one changes when we bump cBioPortal. That split *is* the
  decoupling thesis.
- **`MTB-cbioportal`** — the existing production deployment. Referenced for
  patterns only; nothing here depends on it.
- **`cbioportal-frontend`** (our fork) — where the real MTB features still live,
  and the source for the migration this demo unblocks.

## What this demo does not cover

Deliberately out of scope, so that the mount contract could be proven without
extra failure modes: FhirSpark, authentication/Keycloak, OpenResty, real MTB
data, and any of the actual MTB features. Also out of scope: cBioPortal v7,
which moves the database to ClickHouse — the point of this work is that getting
there becomes a tag bump plus the contract check, not a fork migration.

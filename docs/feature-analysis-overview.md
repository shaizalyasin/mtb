# Feature Analysis Overview

This page provides a technical overview of the custom features developed for the
MTB-cBioPortal, currently implemented as hardcoded React components within a
forked `cbioportal-frontend` repository. It documents each feature and its data
dependencies, and sets out the strategy for extracting them into a standalone
application mounted into upstream cBioPortal.

> **Verification status.** Everything marked **[verified]** was checked against
> `cbioportal-frontend` at tag `v6.4.4` and against a running
> `cbioportal/cbioportal:6.4.4` container in the `mtb-demo` proof of concept.
> Items marked **[assumed]** are reasoned but not yet demonstrated. Corrections
> to earlier revisions of this page are called out in
> [What changed in this revision](#what-changed-in-this-revision).

## Feature Analysis & Data Requirements

The following outlines each custom tab currently injected into the Patient View,
detailing their functionality and data dependencies.

### 1. MTB Tab

**Purpose:** Provides clinical decision support interface allowing clinicians to
document and manage therapy recommendations based on a patient's genomic and
clinical profile.

**Component Path:** `src/pages/patientView/therapyRecommendation`

**Data Requirements:**

- **Read (cBioPortal store)** — the patient's mutation, discrete copy-number and
  clinical data. On `PatientViewPageStore` these are the `remoteData` containers
  `mutationData`, `discreteCNAData`, `clinicalDataPatient` and
  `clinicalDataForSamples`. **[verified]** — field names confirmed at v6.4.4.
- **Read/Write (FhirSpark Backend):** connection to the custom FhirSpark API to
  fetch (`fetchMtbsUsingGET`) and save (`updateMtbUsingPUT`) therapy
  recommendations.
- **Auth:** the OpenResty/Keycloak proxy layer passes authenticated user tokens
  to FhirSpark for write-access authorization. **[assumed]** for the mounted-tab
  case — see [Authentication](#authentication-not-yet-verified).

### 2. Follow-up Tab

**Purpose:** Tracks the side effects and tumor response of previously submitted
MTB therapy recommendations.

**Component Path:** `src/pages/patientView/therapyRecommendation`

**Data Requirements:**

- **Read (FhirSpark):** depends on the existence of `IMtb` (Therapy
  Recommendation) objects. If no MTB session exists, the Follow-up tab cannot be
  utilized.
- **Write (FhirSpark):** submits `IFollowUp` objects via
  `updateFollowupUsingPUT`.

### 3. PROMs (Patient-Reported Outcome Measures)

**Purpose:** Visualizes EQ-5D-5L questionnaire data using timeline charts,
line/scatter plots, and pie charts to track patient well-being over time.

**Component Path:** `src/pages/patientView/proms`

**Data Requirements:**

- **Read (cBioPortal Database):** PROMs does not talk to FhirSpark. It requires
  data imported as Clinical Events (Timeline data) in the standard cBioPortal
  database. **[verified]** — reachable both from `store.clinicalEvents` and from
  `GET /api/studies/{studyId}/patients/{patientId}/clinical-events`.
- **Required schema:** the `ClinicalEvent` must have an `eventType` of
  `EQ-5D-5L`. **[verified]**
- **Required attributes** — the exact strings the code compares against, from
  `src/pages/patientView/proms/utils/EQ-5D-5LChartMetadata.ts`:

  | Key | Role |
  | --- | --- |
  | `DATE_ISO` | `DATE_KEY` — absolute date of the questionnaire |
  | `MOBILITY` | dimension |
  | `SELF-CARE` | dimension |
  | `USUAL_ACTIVITY` | dimension |
  | `PAIN/DISCOMFORT` | dimension |
  | `ANXIETY/DEPRESSION` | dimension |
  | `VAS` | visual analogue score |
  | `INDEX` | EQ index value |

  Lookup is exact string equality (`attributes.find(attr => attr.key === KEY)`),
  so any deviation — including stray whitespace — silently drops that series
  from the charts rather than erroring.

> **Correction.** An earlier revision listed the keys as `DATE`, `EQ_VAS`,
> `INDEX`, `MOBILITY`. The code uses `DATE_ISO` and `VAS`; `DATE` and `EQ_VAS`
> do not appear in the metadata module.

> **Known data defect.** In `asclc_msk_2024`, the header of
> `data_timeline_eq5d5l.txt` reads `<TAB> USUAL_ACTIVITY` with a leading space,
> so the attribute imports as `" USUAL_ACTIVITY"` and PROMs drops that dimension
> without complaint. Fixed in the `mtb-demo` copy; **the source study in
> `MTB-cbioportal` still has it.**

### 4. ClinicalTrialsGov Match

**Purpose:** Dynamically matches the patient against active clinical trials
based on geographic location, age, tumor entity, and molecular profile.

**Component Path:** `src/pages/patientView/clinicalTrialMatch`

**Data Requirements:**

- **Read (cBioPortal):** the patient's genomic profile and clinical demographics
  (Age, Sex, Location) to formulate the search parameters.
- **Read (External):** access to query the public clinicaltrials.gov REST API.
  As a cross-origin browser request this depends on clinicaltrials.gov's CORS
  policy. **[assumed]**

This is a one-shot read with no reactivity requirement, so it is a candidate for
reading via cBioPortal's REST API rather than the store — see
[Choosing between the store and the REST API](#choosing-between-the-store-and-the-rest-api).

### 5. Clinical Timeline (Absolute Dates)

**Purpose:** Extends the cBioPortal clinical timeline by displaying absolute
calendar dates alongside relative dates.

**Component Path:** `src/pages/patientView/timeline`

**Data Requirements:**

- **Dependency:** uses `useDateFormat()` context from the
  `cbioportal-clinical-timeline` library to fetch the patient's `startDate`.
- **Logic:** when a valid absolute `startDate` exists, the tooltip renders a
  dual format: Relative Date (Absolute Date).

**Note:** this is a modification to a core cBioPortal component rather than a
standalone tab, so extracting it requires upstreaming the change or maintaining
a small build-time patch. This is the one feature that does not fit the
decoupled model — see
[Components requiring separate handling](#components-requiring-separate-handling).

### 6. Local Clinical Trials (Beta)

**Purpose:** A rule-engine tab for matching patients against internal,
institution-specific clinical trial registries.

**Component Path:** `src/pages/studyView/tabs`

**Data Requirements:**

- **Read (Static Config):** a structured JSON configuration file (`localCT.json`)
  defining the inclusion/exclusion criteria for local trials.

Note this tab lives on the **Study View**, not the Patient View, so its
`custom_tabs` entry needs `"location": "STUDY_PAGE"` and a study-view tab id.

### 7. EMA Approval Status

**Purpose:** Captures and displays European Medicines Agency approval status as
part of the MTB therapy recommendation workflow. This is not a separate tab, but
an evidence-level extension used to mark recommendations with regulatory
approval information.

**Component Path:** `src/pages/patientView/therapyRecommendation`,
`packages/cbioportal-utils/src/model/TherapyRecommendation.ts`

**Data Requirements:** Read/Write on the `evidenceLevelExtension` field of
`ITherapyRecommendation`.

**UI Behavior:** the MTB recommendation form provides an evidence-level selector
that includes `Z(EMA)`, and the MTB table renders the stored EMA label alongside
the recommendation.

**Migration Note:** must be carried over with the therapy recommendation
form/table logic and the shared model, because it is part of how regulatory
approval metadata is entered and displayed.

---

## Decoupling Strategy & Deployment Architecture

Currently these custom features are tightly coupled to the forked
`cbioportal-frontend` repository. Because cBioPortal is actively developed by
MSKCC, maintaining this fork over the long term is not sustainable, and it makes
the features difficult to share across institutions. We are therefore moving to
a decoupled architecture where the MTB-specific UI lives in a standalone
application and is mounted into the official upstream cBioPortal Patient View
through cBioPortal's native `custom_tabs` mechanism.

**This approach has been demonstrated end to end** against an unmodified
`cbioportal/cbioportal:6.4.4` image in the `mtb-demo` proof of concept.

### Micro-Frontend via custom_tabs callback mounting

The MTB-specific UI is packaged as a standalone application,
`mtb-clinical-tools`, which owns the components previously embedded in the
forked Patient View: `MtbTable`, `FollowUpTable`, `Proms` and
`ClinicalTrialMatch` together with their FhirSpark integration. The application
builds to static JavaScript and CSS bundles, served independently (for example
behind Nginx) alongside the main cBioPortal container.

cBioPortal loads these bundles through its `custom_tabs` configuration. For each
configured tab the runtime appends the `pathsToCSS` stylesheets, loads the
`pathsToJs` bundles once (the dependency promise is cached per tab so assets load
a single time), and then invokes the global function named by
`mountCallbackName` with the signature
`(div, tab, url, store, autorun, isUnmount)`. The callback renders the tab into
the supplied `div`. **[verified]** — `src/shared/lib/customTabs.ts`.

### Reading cBioPortal's data

Because the callback executes inside cBioPortal's own document, the tab has
access to the live `patientViewPageStore`. Patient and study context, mutations,
copy-number data and clinical data are read from this store rather than
re-fetched, so the standalone UI inherits the data cBioPortal has already loaded
and annotated. **[verified]**

> **Correction — important.** An earlier revision stated the store is "passed as
> `store`". **It is not.** At v6.4.4 the Patient View passes a hardcoded `null`
> as the fourth argument:
>
> ```
> PatientViewPageTabs.tsx   buildCustomTabs()
>   customTabHelpers.tsx    customTabCallback()
>                             showCustomTab(div, tab, location.href, null, isUnmount)
>                                                                    ^^^^
> ```
>
> The variant that does pass the store,
> `PatientViewPage.customTabMountCallback`, is dead code at this tag — its only
> call site is commented out in `PatientViewPageTabs.tsx`.
>
> The live store is instead published on the window by the `PatientViewPage`
> constructor:
>
> ```ts
> getBrowserWindow().patientViewPageStore = this.pageStore;
> ```
>
> Mount callbacks should therefore resolve the store defensively, preferring the
> argument so that the code keeps working if upstream repairs the call site:
>
> ```ts
> const pageStore = store ?? (window as any).patientViewPageStore;
> ```

Reactivity comes from the `autorun` passed as the fifth argument — the portal's
own MobX `autorun`. Using it, rather than bundling MobX, is what binds the tab to
the host's observable graph. `remoteData` containers expose
`isPending` / `isComplete` / `isError` / `result`, and must be gated on those
before `.result` is touched. **[verified]** — a mutation count was observed
transitioning from a pending state to the correct value with no remount.

### Choosing between the store and the REST API

There are two ways for a mounted tab to obtain cBioPortal data, and the choice
has consequences for upgrade cost:

| | Store (`window.patientViewPageStore`) | REST API (`/api/...`) |
| --- | --- | --- |
| Stability | Internal, unsupported; can change in any release | Public, supported, versioned |
| Reactivity | Yes, via the injected `autorun` | No — one-shot fetch |
| Cost | Already fetched and annotated | Refetches data the page may already hold |
| Upgrade impact | Requires the contract re-check | None |

Both are **[verified]** working from inside a mounted tab. REST calls are
same-origin from the portal's document, so no CORS configuration is required.

The practical guidance: use the store for anything that must update as
cBioPortal's own fetches land, and the REST API for one-shot reads. Every field
read from the store adds to the surface that must be re-checked on upgrade;
fields read over REST add nothing.

### Session and authentication

Running in the same document means the tab shares cBioPortal's authenticated
session, so requests to the FhirSpark backend should continue to pass through the
existing OpenResty/Keycloak layer without additional token handling.
**[assumed]** — see below.

### Other runtime behaviour

The `url` field is forwarded to the callback as its third argument but is not
otherwise interpreted by the runtime; there is no iframe embedding in this
version. **[verified]**

Callbacks must be idempotent and must clean up when the tab is unmounted, so
switching between Patient View tabs does not leave duplicate content behind.
**[verified]** — the reference implementation keeps one React root per host
`div` in a `WeakMap`, disposes the `autorun` on unmount, and was observed leaving
exactly one panel after repeated tab switching.

Note that unmount only fires if the tab config sets `"unmountOnHide": true`;
`buildCustomTabs` passes `unmountOnHide={thisTab.unmountOnHide === true}`, so it
defaults to false and the teardown path would otherwise never be exercised.

### This approach gives a practical middle ground

- no forked Patient View shell for the MTB UI
- reuse of the official upstream cBioPortal frontend
- a standalone application that owns the MTB-specific UI and logic
- controlled coupling to cBioPortal's tab mount contract and runtime data model

### Configuration

The Patient View custom tabs are declared in `frontend.json`, which is passed to
the backend as `--frontend.config=<path>` and served to the frontend through
`/config_service`. **This is pure runtime configuration — no frontend rebuild is
involved**, so the official pre-built image can be used unmodified. **[verified]**

Each entry points at the standalone app's built bundles and names the global
mount function the runtime calls once they load. `mountCallbackName` is used
rather than `mountCallback` because it lets the bundle own its own code and
avoids `eval`.

> **Correction.** An earlier revision said `mountCallbackName` is required
> "because a function reference cannot be expressed in JSON". A function *can*
> be expressed: `prepareCustomTabConfigurations` runs `eval()` on `mountCallback`
> when it is a string, and the current `MTB-cbioportal/config/frontend.json` does
> exactly that. `mountCallbackName` remains the better choice, for the reasons
> above.

> **Correction — the tab `id` is not free-form.** The id becomes a URL path
> segment and is validated by the router. `customTabParamValidator` in
> `src/routes.tsx` accepts a custom tab only if the path matches one of:
>
> ```
> patient/openResource_.+
> study/<StudyViewResourceTabPrefix>.+
> .+/customTab[0-9]
> ```
>
> and `LocationValidationWrapper` combines it as
> `validator(params) || customTabParamValidator(location)`. Anything else renders
> an `ErrorPage`. The failure mode is misleading: **the tab appears in the tab
> bar and is clickable, and clicking it blanks the entire Patient View.** The ids
> `mtb_customTab` and `proms_customTab` used in an earlier revision of this page
> both fail. Note the third pattern needs a literal `/customTab` followed by a
> digit, so `mtb_customTab0` fails too.

```json
{
  "custom_tabs": [
    {
      "id": "openResource_mtb",
      "title": "MTB",
      "location": "PATIENT_PAGE",
      "pathsToJs": ["https://<our-server>/mtb-tools/assets/mtb-tools.js"],
      "pathsToCSS": ["https://<our-server>/mtb-tools/assets/mtb-tools.css"],
      "mountCallbackName": "renderMtbTab",
      "unmountOnHide": true
    },
    {
      "id": "openResource_proms",
      "title": "PROMs",
      "location": "PATIENT_PAGE",
      "pathsToJs": ["https://<our-server>/mtb-tools/assets/mtb-tools.js"],
      "pathsToCSS": ["https://<our-server>/mtb-tools/assets/mtb-tools.css"],
      "mountCallbackName": "renderPromsTab",
      "unmountOnHide": true
    }
  ]
}
```

One bundle can back many tabs — both entries above point at the same
`mtb-tools.js` and differ only in the global they name.

### Content-Security-Policy

The official 6.4.4 image sets `X-Frame-Options`, `X-Content-Type-Options` and
related headers but **no Content-Security-Policy**, so the bundle can be served
from a separate origin. **[verified]** If a CSP is introduced in a future
release, `script-src` / `style-src` would need to permit the bundle's origin, or
the bundle would need to be served same-origin behind the existing proxy.

### Components requiring separate handling

Two features do not fit the custom-tab model and are handled outside the
`mtb-clinical-tools` bundle:

1. **Clinical Timeline (Absolute Dates)** is a modification to a core cBioPortal
   component rather than a standalone tab, so it cannot be mounted as a custom
   tab. The preferred path is to check whether the timeline library already
   exposes a configuration flag for tooltip date formatting; failing that, to
   upstream the change to `cbioportal-frontend`; and as a last resort, to apply a
   small localized patch during the build (for example via `patch-package`).

   This is the only remaining reason to build anything from cBioPortal source. If
   it is upstreamed, the deployment becomes purely "pull the official image".

2. **EMA Approval Status** is not a tab but an evidence-level extension
   (`evidenceLevelExtension`) on the `ITherapyRecommendation` model in
   `cbioportal-utils`. It is carried over as part of the MTB therapy
   recommendation form, table and shared model. That model must be available to
   the standalone bundle, either by depending on `cbioportal-utils` as a package
   or by vendoring the type into a small shared module.

### Contract drift and the upgrade path

The bundle depends on cBioPortal runtime internals — the mount signature, the
store field names, and the tab-id routing rules — which are not a guaranteed
stable API. The "bump the image tag" upgrade path is real, but **each upgrade
should re-verify that those still hold**. This is a short checklist, not a fork
rebase, and it is automated: `mtb-demo/verify.sh` drives a real browser through
every criterion and can be pointed at a candidate image before committing to the
upgrade.

The full checklist lives in `mtb-clinical-tools/CONTRACT.md`.

---

## Authentication (not yet verified)

The claim that a mounted tab inherits cBioPortal's authenticated session, and
that FhirSpark writes therefore work with no extra token handling, is sound
reasoning but has **not** been demonstrated. The proof of concept deliberately
ran with `authenticate=false` and without Keycloak, OpenResty or FhirSpark, so
that the mount contract could be proven without additional failure modes.

This is the highest-risk remaining assumption, and it gates the MTB and Follow-up
tabs. Two things need checking:

1. Whether same-origin requests from the mounted bundle carry the session as
   expected through OpenResty/Keycloak.
2. Whether FhirSpark requests remain same-origin. Script *loading* is not
   CORS-gated, but a cross-origin `fetch` is — so if FhirSpark is reached on a
   different origin than the portal, it needs CORS configuration.

## What changed in this revision

| # | Earlier statement | Correction |
| --- | --- | --- |
| 1 | The store is "passed as `store`" | It arrives as `null`; read `window.patientViewPageStore` |
| 2 | Example tab ids `mtb_customTab`, `proms_customTab` | Both blank the Patient View; ids must match the router's patterns |
| 3 | `mountCallbackName` needed "because a function cannot be expressed in JSON" | A string `mountCallback` is `eval`'d; the real reasons are code ownership and avoiding `eval` |
| 4 | PROMs keys `DATE`, `EQ_VAS` | The code uses `DATE_ISO` and `VAS` |
| 5 | Auth pass-through stated as fact | Marked as assumed and untested |
| — | — | Added: config is runtime-only (no rebuild), no CSP on the official image, `unmountOnHide` defaults to false, store-vs-REST guidance |

## References

| Resource | Link |
| --- | --- |
| MTB-cBioPortal Deployment | https://github.com/PM4Onco/MTB-cbioportal |
| PM4Onco Frontend Fork | https://github.com/PM4Onco/cbioportal-frontend |
| cBioPortal Frontend | https://github.com/cBioPortal/cbioportal-frontend |
| cBioPortal Backend | https://github.com/cBioPortal/cbioportal |
| cBioPortal Documentation | https://docs.cbioportal.org/deployment |
| Mount contract checklist | `mtb-clinical-tools/CONTRACT.md` |

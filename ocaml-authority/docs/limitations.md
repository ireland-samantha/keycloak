# Limitations

What this prototype does **not** show, and where its results stop
generalising. Findings from the adversarial review that remain open are
listed in `adversarial-review.md`. This page is about the shape of the
experiment itself.

## Scope of the evidence

- **One realm, one story, a handful of principals.** The scenario set is
  small and hand-built. The scenarios were chosen to exercise distinctions
  the model was designed to make, so they are not a neutral sample of
  real-world authorization traffic.
- **The ledger is hand-written.** Nothing derives grants, mandates or effect
  bounds from an organisation's actual policies. In a real deployment the
  ledger duplicates knowledge administrators already hold elsewhere. Keeping
  it consistent with role assignments is an operational cost this prototype
  does not measure.
- **No performance claims.** The adapter starts one OS process per
  evaluated scope. Latency, throughput and memory were not measured, and
  nothing here suggests the design is fit for a hot path.

## Scope of the model

- **Effects are declared, not observed.** The kernel decides on the
  declared intended effect (`threat-model.md` A1). It cannot detect an
  authorized action that goes on to cause an unauthorized downstream effect.
- **Mandate and effect are pushed claims.** In this prototype the requesting
  client asserts them per request. They are not bound into tokens at
  issuance or consent. The kernel checks that the claimed mandate is one the
  grants permit. It cannot check that the client is actually pursuing that
  purpose. Binding the mandate at consent time, for instance via
  parameterized client scopes, is future work.
- **The effect order is deliberately generic.** It has four kinds and three
  audiences. Real systems care about more dimensions: money, data classes,
  irreversibility, jurisdiction. Whether a richer order stays generic
  (hypothesis W3) is untested beyond this vocabulary.
- **Root anchors are roles only.** The adapter projects live role mappings
  for the subject and the actors. A chain rooted at any other principal is
  *unverifiable*, not invalid. Groups, organisations, UMA resource ownership
  and permission tickets are not projected as anchors.
- **Only the UMA grant path carries verified delegation.** Through the
  AuthZEN endpoint the same policy runs, but the subject is a PEP-asserted id
  with no token, so the actor chain is empty.
- **Scopes are evaluated one at a time.** A permission covering several
  scopes is allowed only if every scope is allowed. This is conservative, and
  it differs from how Keycloak's own scope permissions compose.

## Scope of the proof search (H2)

- **Parse-only extraction.** Type references are resolved by simple name
  within the slice. There is no attribution, no classpath and no
  inheritance of members from types outside the slice. Method bodies are
  consulted for exactly one fact: whether they return the `null` literal.
- **The encoding catalogue and its costs are hand-picked.** Verdicts are
  relative to that catalogue. A REFUTED verdict means no encoding *in the
  catalogue* discharges the obligation. It is not a theorem about OCaml.
  Costs only order encodings and have no deeper meaning.
- **Declared types are trusted.** The search reasons about what Java
  declarations say. It cannot see what values actually flow through them.
  An unchecked cast that makes a declaration false at runtime is invisible
  to it, and so is a JSON document hidden inside a `String`.

## Scope of verification

- The OCaml type system enforces the invariants listed under S3. Everything
  else is enforced by code and checked by tests, not proven.
- The certificate checker shares the verdict rule table with the search. It
  is independent of the search *procedure*, not of the rules.

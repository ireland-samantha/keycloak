# `attempt_proof`: the reviewer's findings

This is the record behind the `attempt_proof` row of `../adversarial-review.md`,
transcribed from the reviewer's report.

"Initial" means the first run of
`dune test --build-dir=_build-attack-proof test/proof/adversarial`, before any
fix:

| suite | passed | failed |
|---|---:|---:|
| `test_false_proven` | 25 | 0 |
| `test_evasions` | 18 | 17 (most cascading from the crash in 2k) |
| `test_checker` | 23 | 8 |
| `test_rule_table` | 14 | 10 |

One checker failure and one rule-table failure were mistakes in the
reviewer's own tests. Those tests were corrected; the code was not changed
for them.

Totals: 37 findings, of which 11 were fixed, 16 remain open and 10 held.
Each open finding is pinned by a `known_weakness_*` test in
`test/proof/adversarial/`.

## 1. False PROVEN

Every fixture is compiled and run; `LiesDemo` shows each lie at runtime.

| id | case | verdict | outcome |
|---|---|---|---|
| 1a | unchecked cast `(Map<String,List<String>>) readValue(..., Map.class)` | Represent, Nullability, Keyed of `getClaims()` all PROVEN; at runtime it holds an Integer and a String | open |
| 1b | heap pollution through a raw type | raw parameter UNKNOWN (held); polluted `getNames()` PROVEN | open |
| 1c | `String` field holding JSON | PROVEN | open |
| 1d | `@SuppressWarnings("unchecked")` generic arrays | PROVEN; both throw ClassCastException | open |
| 1e | `Optional` returned as `null` | Represent UNKNOWN (Optional is external); value is an `option` | held |
| 1f | setter that throws `UnsupportedOperationException` | Mutable PROVEN | open |
| 1g | case-insensitive `TreeSet` | Unique PROVEN | open |

## 2. Extractor evasions

All fixtures pass `javac`. `javap` confirms no member is dropped in any of
the 22 types.

| id | case | outcome |
|---|---|---|
| 2a | Inner class using the outer type parameter `<Mode>` resolved to a slice enum (false PROVEN) | fixed |
| 2b | Two nested `Entry` types in different outers | held |
| 2c | Fully-qualified or imported external with a slice type's simple name | held |
| 2 (`var`) | `var` in method bodies | held |
| 2d | `import static Outer.Mode` resolves to the top-level enum | open |
| 2e | Wildcard import of the slice package: the type becomes external (UNKNOWN, conservative) | open |
| 2e′ | An external named like a slice id made the checker reject the prover's own certificate | fixed |
| 2f | `Nonnull`/`NotNull` matched by simple name from any package | open |
| 2g | `return (String) null`, `-> null`, `yield null` were missed (false STRENGTHENED under `@Nonnull`) | fixed |
| 2g | `null` inside a lambda is not the method's null | held |
| 2g | Runtime `null` via a lambda behind `@Nonnull` | open |
| 2h | `"..."` inside a comment flagged as varargs | fixed |
| 2i | Arrays of generics; C-style array declarators | held |
| 2j | Interface extending two slice interfaces: the subtype encoded as `unit` still gets `Subtype` PROVEN | open |
| 2k | Legal overloads (`<T extends Policy>` / `<T extends Scope> register(T)`) crashed `prove` with a duplicate obligation id | fixed |
| 2l | Same simple top-level name in two packages aborts the extractor | open |

## 3. Checker soundness

| id | case | outcome |
|---|---|---|
| 3a | OCaml type strings that do not match the encoding (4 variants) | held |
| 3b | Swapped obligation ids | held |
| 3b | Wrong or missing `line` accepted | fixed |
| 3b | False counterexample / bogus `conflicts` accepted | open |
| 3b | Bogus search statistics accepted | open |
| 3c | Reordered obligations or encodings (semantically identical) | held |
| 3d | Digest over key order: not canonical, so it can only cause false rejections | held |
| 3d | MD5 as the digest | open |
| 3e | Allowed encodings whose emitted OCaml did not compile. The triggers were a generic getter in a Record; enum constants `_HIDDEN`, `$DOLLAR`, and `Low` next to `low`; non-ASCII names; and a type named `_Hidden` | fixed |
| 3f | Suboptimal certificates accepted: REFUTED is certified only relative to the certificate's own encodings | open |

## 4. Rule table vs. `proof-search.md`

| id | issue | outcome |
|---|---|---|
| 4a | `Set<List<String>>`, `Set<String[]>`, `Map<Set<String>,_>` and `Set<? extends E>` were PROVEN unique, although the emitted type was a plain list | fixed |
| 4b | `List<? super Integer>` emitted as `int list` and PROVEN | fixed |
| 4c | Checked PROVEN, but a throwing Record getter was emitted without `(_, exn) result` | fixed |
| 4d | A setter whose type differs from its getter's had its value carried nowhere | fixed |

## 5. Documented deviations, left unchanged

Each is pinned as a `doc_deviation_*` test:

- a Query obligation for nullary non-getters
- Represent PROVEN for `Object`, raw types and `Class`
- a `java.lang.Object` bound gives Bounded PROVEN
- a type-variable or external element gives Unique UNKNOWN
- arrays and boxed scalars are Represent PROVEN
- a static Query is PROVEN even on a Variant owner
- the design doc contradicts itself on Record comparability; the code
  follows the rule-table row

## Result

After the fixes, the real Keycloak slice's graph, certificate, emitted `.ml`
and report are byte-identical to before (`cmp`).

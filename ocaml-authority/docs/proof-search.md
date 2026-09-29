# `attempt_proof`: projecting Java authorization types into OCaml

> Java says: this is how authorization works. OCaml replies: prove it.

This document specifies the second experiment (H2 in `hypothesis.md`). The
design sections were written before implementation. Results are appended at
the end and never edit the design above them.

## Problem statement

Input: a **Java source graph** extracted from a slice of Keycloak. The nodes
are types (classes, interfaces, enums, records). Edges are "member of type
`A` mentions type `B`".

Output: an **OCaml type graph**, meaning one encoding choice per Java type
plus the OCaml type expression of each member, together with a
**certificate** that gives one verdict per obligation.

Goal:

    argmin over OCaml graphs O of  cost(O)
    subject to  Obligations(J) ⊆ Guarantees(O) ∪ {explicitly REFUTED or UNKNOWN}

`cost` is lexicographic: (number of REFUTED, number of UNKNOWN, complexity).
The OCaml graph may be stricter than Java only where the Java source contains
evidence for it. It is never weaker. An obligation that cannot be met without
weakening is reported as REFUTED with a counterexample. It is never silently
dropped.

## The slice

Paths are relative to the repository root, at baseline commit `6688a3d6`.

```
server-spi-private/src/main/java/org/keycloak/authorization/model/Policy.java
server-spi-private/src/main/java/org/keycloak/authorization/model/Resource.java
server-spi-private/src/main/java/org/keycloak/authorization/model/ResourceServer.java
server-spi-private/src/main/java/org/keycloak/authorization/model/Scope.java
server-spi-private/src/main/java/org/keycloak/authorization/model/PermissionTicket.java
server-spi-private/src/main/java/org/keycloak/authorization/identity/Identity.java
server-spi-private/src/main/java/org/keycloak/authorization/attribute/Attributes.java
server-spi-private/src/main/java/org/keycloak/authorization/permission/ResourcePermission.java
server-spi-private/src/main/java/org/keycloak/authorization/policy/evaluation/Evaluation.java
server-spi-private/src/main/java/org/keycloak/authorization/policy/evaluation/EvaluationContext.java
server-spi-private/src/main/java/org/keycloak/authorization/policy/evaluation/Realm.java
server-spi-private/src/main/java/org/keycloak/authorization/policy/provider/PolicyProvider.java
server-spi-private/src/main/java/org/keycloak/authorization/policy/provider/PolicyProviderFactory.java
server-spi-private/src/main/java/org/keycloak/authorization/Decision.java
core/src/main/java/org/keycloak/representations/idm/authorization/DecisionStrategy.java
core/src/main/java/org/keycloak/representations/idm/authorization/Logic.java
core/src/main/java/org/keycloak/representations/idm/authorization/PolicyEnforcementMode.java
core/src/main/java/org/keycloak/representations/JsonWebToken.java
authzen/services/src/main/java/org/keycloak/authorization/authzen/AuthZen.java
```

## Pipeline

```
Keycloak .java files
   │  tools/java-graph/JavaGraph.java    (JDK compiler tree API, parse only; no Keycloak classpath)
   ▼
examples/proof/keycloak-authz.graph.json          (committed, so the OCaml side runs without Java)
   │  lib/proof: decode → obligations → SCC condensation → attempt_proof (memoized DP)
   ▼
examples/proof/certificate.json                   (verdict per obligation, with counterexamples)
examples/proof/keycloak_authz_types.ml            (emitted OCaml type graph; compiled by dune)
   │  Certificate.check (independent; re-derives obligations; no search)
   ▼
accept / reject
```

The extractor is parse-only on purpose. Type references are resolved by
simple name within the slice. Anything else is either a known JDK type
(`String`, `List`, `Set`, `Map`, `Collection`, `Object`, boxed primitives,
`Class`) or *external*.

## Obligations

The extractor records members as data. A member is a field, a record
component, or a method: its name, parameters, return type, `throws` clause,
modifiers and annotations, plus two body facts. The body facts are "returns
the `null` literal somewhere" and "has a body" (for `default` methods).

Obligations are derived from these members.

| obligation | arises from | fact to preserve |
|---|---|---|
| `Represent(m, J)` | every member with a value type `J` | values of `J` can be carried |
| `Nullability(m, ev)` | every reference-typed member | Java admits `null`. Evidence `ev` is `returns_null`, `@Nullable`, `@Nonnull`/`@NotNull`, or none. |
| `Closed(T, constants)` | enum `T` | exactly these values |
| `Open(T)` | an interface that extends `Provider`/`ProviderFactory` or whose name ends in `Provider`/`Factory` | third parties add implementations |
| `Unique(m, E)` | `Set<E>` | no duplicates, by Java `equals` |
| `Keyed(m, K, V)` | `Map<K,V>` | unique keys, by Java `equals` |
| `Command(m)` | `void` method that is not a setter | side effect with no value |
| `Query(m)` | non-`void` method with parameters | function of arguments |
| `Mutable(m)` | setter `setX`, or non-`final` field | value changes after construction |
| `Checked(m, X)` | `throws X` | failure is part of the signature |
| `Bounded(T, P, B)` | type parameter `P extends B` | instantiations are subtypes of `B` |
| `Subtype(S, T)` | `S extends/implements T`, both in slice | values of `S` usable as `T` |
| `Dynamic(m)` | `Object`-typed values, raw types, `Class<?>` | none statically; the Java type system opted out |

Getters `getX()` and `isX()` without parameters are data members.
`default` and `static` methods are included; `static` members do not become
fields.

## Node encodings

| encoding | allowed for | comparable | allowed in a cyclic SCC | open | complexity |
|---|---|---|---|---|---|
| `Variant` | enums only | yes | yes | no | 1 |
| `Record` | any class, interface or record. Non-data members (commands, queries) cannot be carried and become REFUTED. | yes, if every field is | yes | snapshot | 2 |
| `Closures` (record of functions) | any interface or class | **no** | yes | yes | 3 |
| `Object` (OCaml object type) | any interface or class | **no** | yes | yes | 4 |
| `Module_type` | interfaces only | **no** | **no** | yes | 5 |
| `Abstract` | external types only | unknown | yes | n/a | 1 |

## Verdict rules

| obligation | verdict |
|---|---|
| `Represent` | `boolean→bool`, `int/short/byte/char→int`, `String→string`, `double/float→float`: PROVEN. `long→Int64.t`: PROVEN; `long→int` would be weaker (63-bit), so it is never chosen. `List/Collection<E>→E list`: PROVEN. `T` in the slice → reference to `T`'s encoding: PROVEN. External `T`: UNKNOWN. |
| `Nullability` | Evidence of null → `option`: STRENGTHENED (a runtime fact is made static). `@Nonnull` → bare type: STRENGTHENED. No evidence → `option`: PROVEN, faithful to Java's nullable-by-default references. A bare type without evidence would be weaker, so it is never chosen. |
| `Closed` | `Variant`: PROVEN |
| `Open` | `Closures`, `Object` or `Module_type`: PROVEN. `Record`: UNKNOWN (a data snapshot assumes getters are pure). `Variant`: never chosen. |
| `Unique` / `Keyed` | Element or key is `String`, a primitive or an enum → `Set.Make` or `Map.Make`: PROVEN. Element is a slice type encoded `Record` → UNKNOWN, because Java `equals` is implementation-defined and structural compare may differ. Element encoded non-comparable (`Closures`, `Object`, `Module_type`) → REFUTED, since a list would lose uniqueness. |
| `Command` / `Query` | Owner encoded `Closures`, `Object` or `Module_type` → closure: PROVEN. Owner encoded `Record` → REFUTED, with counterexample "a record cannot carry behaviour". |
| `Mutable` | `mutable` field or setter closure: PROVEN |
| `Checked` | `(_, exn) result` return type: PROVEN |
| `Bounded` | Bound `B` encoded `Object` → row-constrained parameter (`'p constraint 'p = < ..; b-methods >`): PROVEN. Otherwise REFUTED: OCaml type parameters carry no bounds. |
| `Subtype` | Both `Object`: PROVEN at complexity 0 (structural). Both `Module_type`: `include`, complexity 1. Same encoding otherwise: coercion function, complexity 2. Different encodings: complexity 3. Always PROVEN; the cost pushes hierarchies toward consistent encodings. |
| `Dynamic` | UNKNOWN: the Java type states no fact to preserve |

## Search: `attempt_proof`

1. Build the type-reference graph and condense it into strongly connected
   components (Tarjan).
2. Order the components topologically, **referrers first**.
3. The search state is `(k, demands)`:
   - `k` is the index of the next component to assign
   - `demands` holds the requirements already placed on components `≥ k`
     by their referrers (e.g. "`Scope` must be comparable because `Policy`
     has `Set<Scope>`", or "`B` must be `Object`, because it is a bound")

   Assigned components can never be referrers of later ones, so a
   component's demands are final when it is reached.
4. `attempt_proof (k, demands)` enumerates the encodings allowed for
   component `k` and backtracks from infeasible choices (e.g. `Module_type`
   inside a cycle). For each choice it scores component `k`'s own
   obligations. Unmet demands on `k` become REFUTED or UNKNOWN verdicts
   charged to the referrer's obligation. It then emits new demands on
   components `> k` and recurses.
5. **Memoization.** Results are memoized on the canonicalized state: `k`
   plus demands restricted to components `≥ k`. Many different assignments
   of early components produce the same residual demands, which is where
   the DP pays. Branch-and-bound prunes any partial cost that already meets
   the best complete cost.
6. The search counts states explored, memo hits and branches pruned, and
   reports the counts exactly as measured.

`attempt_proof` returns

```
type proof_result =
  | Proven  of ocaml_graph * certificate            (* every obligation PROVEN or STRENGTHENED *)
  | Refuted of ocaml_graph * certificate * counterexample list
  | Unknown of ocaml_graph * certificate * unresolved list   (* no REFUTED, some UNKNOWN *)
```

The best graph and certificate are always included. A refutation is a
result, not an absence of one.

## Certificate checking

`Certificate.check java_graph ocaml_graph certificate` does not search. It:

1. re-derives the obligations from the Java graph and checks the certificate
   covers each exactly once
2. recomputes each verdict from the chosen encodings with the rule table
3. checks the structural constraints (e.g. no `Module_type` in a cycle)
4. recomputes the cost

The checker is the trusted part. The search is untrusted and may be as
clever as it likes.

## Verification of the search itself

Hypothesis P2 requires the following checks:

- For randomized small graphs (≤ 7 nodes), the DP cost equals the cost of
  exhaustive enumeration of all assignments.
- On a constructed graph, a greedy per-node strategy (pick each node's
  locally cheapest encoding) produces strictly more REFUTED obligations than
  the DP.
- The certificate checker rejects a certificate after any single verdict is
  altered.

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

## Results

Appended after implementation. The design sections above are unchanged.
Every number below is printed by a command listed here, and the committed
`examples/proof/report.txt` is that command's output, regenerated and
compared by `dune test`.

### Reproducing

```
# from ocaml-authority/
java tools/java-graph/JavaGraph.java --root .. \
    --commit 6688a3d63f59e0c4a9131bfdd556c4312799f04e \
    --slice tools/java-graph/authz-slice.txt --out examples/proof/keycloak-authz.graph.json
dune build --build-dir=_build-proof ./bin/prove/main.exe
./_build-proof/default/bin/prove/main.exe examples/proof/keycloak-authz.graph.json \
    --certificate examples/proof/certificate.json --emit examples/proof/keycloak_authz_types.ml --report
./_build-proof/default/bin/prove/main.exe --check examples/proof/keycloak-authz.graph.json examples/proof/certificate.json
dune test --build-dir=_build-proof examples/proof test/proof
```

The graph records the git blob hash of each of the 19 files. All 19 equal
`git ls-tree 6688a3d6` for the same paths, so the graph is of the baseline
commit even though the extractor reads the working tree.

### The real slice

| | |
|---|---|
| types | 36: 13 interfaces, 4 classes, 10 enums, 9 records (17 of them nested) |
| external types | 13, all `Abstract` |
| obligations | 760 |
| result | `Refuted`, cost (refuted 3, unknown 29, complexity 88) |
| checker | accepts: 760 obligations re-derived, verdicts and cost recomputed |
| emitted OCaml | `keycloak_authz_types.ml`, 592 lines, compiles under the project's dune warning set |

| kind | PROVEN | STRENGTHENED | UNKNOWN | REFUTED |
|---|---:|---:|---:|---:|
| Represent | 305 | 0 | 16 | 0 |
| Nullability | 263 | 7 | 0 | 0 |
| Closed | 10 | 0 | 0 | 0 |
| Open | 2 | 0 | 0 | 0 |
| Unique | 5 | 0 | 2 | 2 |
| Keyed | 16 | 0 | 0 | 0 |
| Command | 29 | 0 | 0 | 0 |
| Query | 57 | 0 | 0 | 0 |
| Mutable | 33 | 0 | 0 | 0 |
| Bounded | 1 | 0 | 0 | 1 |
| Dynamic | 0 | 0 | 11 | 0 |
| **total** | **721** | **7** | **29** | **3** |

No `Subtype` or `Checked` obligation arises: no slice type extends another
slice type, and no signature in the slice declares `throws`.

Encodings chosen: every enum is `Variant`; `Scope`, `ResourceServer`,
`PermissionTicket`, `EvaluationContext`, `AuthZen` and the nine AuthZEN records
are `Record`; `Policy`, `Resource`, `Identity`, `Realm`, `Attributes`,
`Attributes.Entry`, `ResourcePermission`, `JsonWebToken`, `Decision`,
`PolicyProvider` and `PolicyProviderFactory` are `Closures`; `Evaluation` is
`Object`, because it bounds `Decision<D extends Evaluation>`.

The three refutations:

- `Unique:Policy.getAssociatedPolicies()@return`: `Set<Policy>` needs a
  comparable `Policy`, but a `Record` cannot carry `Policy`'s eight commands
  (`removeConfig`, `putConfig`, `addScope`, ...). The counterexample in the
  certificate names all eight.
- `Unique:Policy.getResources()@return`: the same trade-off for `Resource`,
  whose six commands and queries (`updateUris`, `updateScopes`,
  `getSingleAttribute`, ...) need closures.
- `Bounded:PolicyProviderFactory@<R extends AbstractPolicyRepresentation>`: the
  bound is outside the slice, so there is no object type to constrain `R` by.

The 29 UNKNOWN verdicts: 16 `Represent` of types outside the slice (9 of
them `AuthorizationProvider`, in `Evaluation` and in `PolicyProviderFactory`'s
parameters), 11 `Dynamic` (`Object` in the AuthZEN `properties`/`context` maps,
in `JsonWebToken`'s other claims and `equals(Object)`, and `Class<R>`), and 2 `Unique` of
`Set<Scope>` (`Scope` is a `Record`, so Java `equals` may differ from
structural comparison). The full list with reasons is in `report.txt`.

The 7 STRENGTHENED verdicts are all `returns_null` evidence:
`PolicyProviderFactory.getDescription`, `getCode`, `getAdminResource`,
`Attributes.getValue`, and the three `valueOfInteger` factories of the
core enums.

### Search

| | real slice |
|---|---:|
| components (SCCs) | 36 |
| cyclic components | 7, all self-loops |
| largest component | 1 |
| states explored | 36 |
| memo hits | 27 |
| branches pruned | 18 |
| encodings rejected as infeasible (`Module_type` in a cycle) | 2 |

The condensation of the real slice is a DAG of 36 single types. The cycles
are self-references: `Policy` (`Set<Policy>`, `addAssociatedPolicy(Policy)`),
`JsonWebToken` (fluent setters), `Attributes` (`static from(...)`) and four
enums whose static `valueOfInteger` returns the enum. The DP is therefore
shallow on this slice. Memo hits happen where two encodings of one component
leave identical residual demands. For example, `Closures` and `Object` for
`Policy` both leave nothing pending, so the second is answered from the memo.
The demand machinery is exercised all the same: `Unique:Policy.getScopes()`
is decided at the last enum component it reaches, via
`Policy -> Scope (Record) -> ResourceServer (Record) -> PolicyEnforcementMode, DecisionStrategy`.

P2, as measured by `dune test --build-dir=_build-proof test/proof`:

- (a) On 250 random graphs (seed 20260929, 1 to 7 types, 6066 obligations; 95
  with `Subtype`, 123 with `Bounded`, 90 with `Open`, 76 with a component of
  two or more types), the DP's cost equals exhaustive enumeration in every
  case. Across all 250 graphs, brute force scored 64242 assignments and the DP
  explored 1363 states with 1509 memo hits and 2631 pruned branches. The DP's
  own per-obligation verdicts, reached incrementally through demands, also
  equal the checker's global evaluation of its assignment. Two deliberate
  bugs were each detected by this test: dropping cross-component
  comparability demands failed 344 checks, and dropping cross-component
  `Subtype` complexity failed 149.
- (b) On a four-type constructed graph, greedy per-node choice has 2 REFUTED
  and the DP has 0. On the real slice, greedy has 4 REFUTED and the DP has 3:
  greedy keeps `Evaluation` as `Closures`, the locally cheapest encoding, and
  so refutes `Bounded:Decision@<D extends Evaluation>`.
- (c) The checker rejects all 2280 single-verdict mutations of the real
  certificate (760 obligations times 3 other verdicts), and all 144
  single-encoding changes.
- (d) Memo hits on the real slice: 27.

### What the projection cannot see

The extractor is parse-only. Names resolve by lexical scope, single-type
imports, same-package slice types and a fixed `java.lang` list. It does not
see inherited member types, static imports, annotation processing, or
anything that needs attribution. `PolicyProviderAdminService` is recorded as
`assumed_same_package` because nothing imports it; that guess happens to be
right. Bodies contribute exactly two facts, `returns_null_literal` and
`has_body`. No verdict rule reads `has_body`.

The search trusts declared types. At `services/.../AuthorizationTokenService.java:127`
(outside the slice, inside a lambda body), pushed claims are decoded with an
unchecked conversion,
`Map<String, List<String>> claimTokenClaims = JsonSerialization.readValue(..., Map.class)`.
They then reach `ResourcePermission` through `request.setClaims` (line 136) and
`new ResourcePermission(..., request.getClaims())` (lines 619 and 740). The
declared element types are never checked at run time, because generics are
erased. The projection cannot see this: it is a body fact, in a file outside
the slice, about a type argument that no declaration states. The obligations
it would undermine are all PROVEN:
`Keyed:ResourcePermission.getClaims()@return`,
`Unique:ResourcePermission.getClaims()@return/1` and the two `addClaims`
counterparts. This is the Q2 failure mode ("false comfort") in its purest
form. The same holds for the pre-registered prediction: `Attributes.toMap()`
is `Map<String, Collection<String>>`, and its `Represent` and `Keyed`
obligations are PROVEN, whatever authorization meaning the strings carry.

### Implementation notes

Implementation note: the `java-source-graph/v1` schema is defined by
`tools/java-graph/JavaGraph.java` and decoded strictly by
`lib/proof/jgraph.ml`. A type reference is `void`, `primitive`, `array`,
`type_var`, `wildcard` or `class`. A `class` reference carries `resolution`
(`slice` | `jdk` | `external`), the resolved `name` (a slice id such as
`Decision.Effect`, or a qualified name) and the resolution `basis`. Modifiers
are effective: those written, plus those the JLS implies for interface
members, enum constants and nested types. Constructors are recorded with kind
`constructor`.

Implementation note: readings of the obligation table.
- The value positions of a member are its field or component type, its
  method return type, and each parameter type. `Represent`, `Nullability`,
  `Unique`, `Keyed` and `Dynamic` are derived per position, and `Unique` and
  `Keyed` at every `Set`/`Map` nested in a position.
- Private members and constructors produce no obligations and no edges.
- A setter is `void setX(one parameter)`. A method that is neither a getter
  nor a setter is a `Command` if it returns `void`, and a `Query` otherwise,
  including nullary non-getters such as `toMap()` and `hashCode()`.
- A static method is a module-level function, so its `Command`/`Query` is
  PROVEN whatever its owner's encoding; the same holds for static `Mutable`.
- A `Variant` owner carries instance methods as functions over the variant
  (PROVEN), but cannot carry `Mutable` (REFUTED). Neither case occurs in the
  slice.
- Comparability is transitive through record fields, as the encoding table's
  "yes, if every field is" requires. A `Record` element whose field is
  encoded non-comparably makes `Unique`/`Keyed` REFUTED. A field reaching an
  external, dynamic or type-variable leaf makes it UNKNOWN.
- `Object`, `Class<...>`, raw types and unbounded wildcards are carried by an
  opaque `java_object` or `java_class` (`Represent` PROVEN). The missing
  static fact is counted once, by `Dynamic`.
- A bound outside the slice is encoded `Abstract`, not `Object`, so
  `Bounded` is REFUTED.
- External types, including supertypes outside the slice, are `Abstract`
  nodes. Their complexity is 1 each and is included in the cost as a
  constant.

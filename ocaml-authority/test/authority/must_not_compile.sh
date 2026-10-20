#!/bin/sh
# must_not_compile.sh OCAMLC AUTHORITY_CMI_DIR TJSON_CMI_DIR SNIPPET_DIR
#
# Type-checks every SNIPPET_DIR/*.ml with plain ocamlc (-i: type-check only,
# write nothing) against the given .cmi directories. A snippet's
# "(* expect: TEXT *)" lines say what must happen: "compiles", or a fragment
# of the compiler's error (whitespace-normalised) that must appear. Exits 1 if
# any snippet compiles when it must not, fails for a different reason, or a
# control snippet does not compile.
set -u
ocamlc=$1 authority=$2 tjson=$3 dir=$4
status=0
for snippet in "$dir"/*.ml; do
  expected=$(sed -n 's/^(\* expect: \(.*\) \*)$/\1/p' "$snippet")
  if [ -z "$expected" ]; then echo "FAIL $snippet: no (* expect: ... *) line"; status=1; continue; fi
  output=$("$ocamlc" -i -I "$authority" -I "$tjson" "$snippet" 2>&1)
  compiled=$?
  flat=$(printf '%s' "$output" | tr '\n\t' '  ' | tr -s ' ')
  if [ "$expected" = compiles ]; then
    if [ $compiled -eq 0 ]; then echo "ok   $snippet compiles (control)"
    else echo "FAIL $snippet: the control snippet does not compile:"; echo "$output"; status=1; fi
    continue
  fi
  if [ $compiled -eq 0 ]; then echo "FAIL $snippet compiled; it must not"; status=1; continue; fi
  missing=$(printf '%s\n' "$expected" | while IFS= read -r fragment; do
    case "$flat" in *"$fragment"*) ;; *) echo "$fragment" ;; esac
  done)
  if [ -z "$missing" ]; then
    echo "ok   $snippet rejected: $(printf '%s' "$expected" | tr '\n' '|')"
  else
    echo "FAIL $snippet rejected for another reason; missing: $missing"; echo "$output"; status=1
  fi
done
exit $status

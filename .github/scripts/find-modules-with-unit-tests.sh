#!/bin/bash -e

find . -path '**/src/test/java' -type d \
  | grep -v -E '\./(docs|distribution|operator|((.+/)?tests)|testsuite|test-framework|quarkus|ocaml-authority)/' \
  | sed 's|/src/test/java||' \
  | sed 's|./||' \
  | sort \
  | tr '\n' ',' \
  | sed 's/,$//'
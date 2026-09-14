import assert from "node:assert/strict";
import test from "node:test";
import { rolesForPrincipal } from "./roles.ts";

test("seed principal keeps the configured privileged role", () => {
  assert.equal(
    rolesForPrincipal(
      "seed@example.com",
      ["seed@example.com"],
      "ROLE_ADMINISTRATOR",
    ),
    "ROLE_ADMINISTRATOR",
  );
});

test("non-seed principals receive only ROLE_AUTHENTICATED", () => {
  assert.equal(
    rolesForPrincipal(
      "user@example.com",
      ["seed@example.com"],
      "ROLE_ADMINISTRATOR",
    ),
    "ROLE_AUTHENTICATED",
  );
});

test("seed principal matching is case-insensitive", () => {
  assert.equal(
    rolesForPrincipal(
      "Seed@Example.com",
      ["seed@example.com"],
      "ROLE_ADMINISTRATOR",
    ),
    "ROLE_ADMINISTRATOR",
  );
});

test("no configured seed principals keep users authenticated only", () => {
  assert.equal(
    rolesForPrincipal("anyone@example.com", [], "ROLE_ADMINISTRATOR"),
    "ROLE_AUTHENTICATED",
  );
});

test("blank principals never receive a privileged role", () => {
  assert.equal(
    rolesForPrincipal("   ", ["seed@example.com"], "ROLE_ADMINISTRATOR"),
    "ROLE_AUTHENTICATED",
  );
});

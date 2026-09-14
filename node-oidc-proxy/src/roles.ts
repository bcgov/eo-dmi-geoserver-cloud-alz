const AUTHENTICATED_ROLE = "ROLE_AUTHENTICATED";

export function rolesForPrincipal(
  principal: string,
  seedPrincipals: readonly string[],
  privilegedRoles: string,
): string {
  const normalizedPrincipal = principal.trim().toLowerCase();
  const isSeedPrincipal = seedPrincipals.some(
    (seedPrincipal) =>
      seedPrincipal.trim().toLowerCase() === normalizedPrincipal,
  );

  return isSeedPrincipal ? privilegedRoles : AUTHENTICATED_ROLE;
}

/** @type {import('dependency-cruiser').IConfiguration} */
module.exports = {
  forbidden: [
    {
      name: "no-circular",
      severity: "error",
      comment: "Circular dependencies cause tight coupling and are hard to reason about",
      from: {},
      to: { circular: true },
    },
    {
      name: "no-orphans",
      severity: "warn",
      comment: "Orphan modules are not imported anywhere — dead code candidates",
      from: { orphan: true, pathNot: ["\\.(test|spec)\\.ts$", "^src/index\\.ts$"] },
      to: {},
    },
    {
      name: "no-dev-deps-in-production",
      severity: "error",
      comment: "Production code must not import devDependencies",
      from: { path: "^src/", pathNot: "\\.(test|spec)\\.ts$" },
      to: { dependencyTypes: ["npm-dev"] },
    },
  ],
  options: {
    doNotFollow: { path: "node_modules" },
    tsPreCompilationDeps: true,
    enhancedResolveOptions: {
      exportsFields: ["exports"],
      conditionNames: ["import", "require", "node", "default"],
    },
  },
};

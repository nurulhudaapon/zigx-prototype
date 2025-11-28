import Bun, { $ } from "bun";
import { copyFileSync, mkdirSync, writeFileSync } from "fs";
import { readFile } from "fs/promises";
import { join } from "path";

const rootDir = process.cwd();
const distDir = join(rootDir, "dist");

async function main() {
  const startTime = Date.now();
  const builtPackages = [];
  const pkg = "";
  const rootReadmePath = join(rootDir, "../../README.md");
  const rootPackageJsonPath = join(rootDir, "package.json");
  const pkgDir = join(rootDir, pkg);
  const pkgDistDir = join(distDir, pkg);
  const pkgJsonPath = join(pkgDir, "package.json");
  const rootPackageJson = JSON.parse(
    await readFile(rootPackageJsonPath, "utf-8"),
  );
  const pkgJson = JSON.parse(await readFile(pkgJsonPath, "utf-8"));
  const pkgName = `${pkgJson.name}`;
  mkdirSync(pkgDistDir, { recursive: true });

  // Build the package
  console.log(`\x1b[33m📦 ${pkgName} - Bundling...\x1b[0m`);
  await $`rm -rf ${pkgDistDir}`.quiet();
  
  // Build main entry
  Bun.build({
    entrypoints: [join(pkgDir, "src/index.ts"), join(pkgDir, "src/react/index.ts"), join(pkgDir, "src/wasm/index.ts")],
    outdir: pkgDistDir,
    minify: true,
  });

  // Generate TypeScript declaration files
  console.log(`\x1b[34m🔷 ${pkgName} - Generating types...\x1b[0m`);
  try {
    // Check if tsconfig.json exists in the package directory
    const tsconfigPath = join(pkgDir, "tsconfig.json");

    // Create a temporary tsconfig for this package
    const tempTsConfigPath = join(pkgDir, "temp-tsconfig.json");
    const tsConfig = {
      compilerOptions: {
        target: "ES2020",
        module: "esnext",
        lib: ["ES2020", "dom"],
        strict: true,
        esModuleInterop: true,
        skipLibCheck: true,
        forceConsistentCasingInFileNames: true,
        moduleResolution: "node",
        resolveJsonModule: true,
        rootDir: "./src",
        outDir: pkgDistDir,
        declaration: true,
        sourceMap: true,
        emitDeclarationOnly: true,
      },
      exclude: ["node_modules", "dist", "test"],
      include: ["./src/**/*.ts"],
    };

    writeFileSync(tempTsConfigPath, JSON.stringify(tsConfig, null, 2));

    // Use the temporary tsconfig and run tsc directly in the package directory
    await $`cd ${pkgDir} && tsc --project ${tempTsConfigPath}`;
    await $`rm dist/zx.d.ts`;

    // Clean up temporary tsconfig
    await $`rm ${tempTsConfigPath}`;
  } catch (error) {
    console.error(
      `\x1b[31m❌ ${pkgName} - Error: Failed to generate type declarations: ${error}\x1b[0m`,
    );
  }

  // Update package.json
  pkgJson.main = "index.js";
  pkgJson.module = "index.js";
  pkgJson.types = "index.d.ts";
  pkgJson.description = rootPackageJson.description;
  pkgJson.homepage = rootPackageJson.homepage;
  pkgJson.keywords = rootPackageJson.keywords;
  pkgJson.repository = rootPackageJson.repository;
  pkgJson.author = rootPackageJson.author;
  pkgJson.license = rootPackageJson.license;
  pkgJson.scripts = undefined;
  pkgJson.devDependencies = undefined;
  pkgJson.peerDependencies = undefined;
  pkgJson.private = undefined;
  pkgJson.release = undefined;
  pkgJson.prettier = undefined;

  // Write updated package.json to dist
  const distPkgJsonPath = join(pkgDistDir, "package.json");
  writeFileSync(distPkgJsonPath, JSON.stringify(pkgJson, null, 2));

  // Copy README.md to dist
  const distReadmePath = join(pkgDistDir, "README.md");
  copyFileSync(rootReadmePath, distReadmePath);

  console.log(`\x1b[32m✅ ${pkgName} - Done\x1b[0m\n`);
  builtPackages.push(pkgName);

  const duration = ((Date.now() - startTime) / 1000).toFixed(2);
  console.log(
    `\x1b[32m✨ Build complete. ${builtPackages.length} packages built in ${duration}s.\x1b[0m`,
  );
}

main();

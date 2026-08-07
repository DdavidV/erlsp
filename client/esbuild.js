const esbuild = require("esbuild");

const watch = process.argv.includes("--watch");

async function main() {
  const extensionCtx = await esbuild.context({
    entryPoints: ["src/extension.ts"],
    bundle: true,
    outfile: "out/extension.js",
    external: ["vscode"],
    format: "cjs",
    platform: "node",
    sourcemap: true,
    minify: !watch,
  });

  const callGraphViewCtx = await esbuild.context({
    entryPoints: ["src/callGraphView.ts"],
    bundle: true,
    outfile: "out/callGraphView.js",
    format: "iife",
    platform: "browser",
    sourcemap: true,
    minify: !watch,
  });

  if (watch) {
    await extensionCtx.watch();
    await callGraphViewCtx.watch();
  } else {
    await extensionCtx.rebuild();
    await extensionCtx.dispose();
    await callGraphViewCtx.rebuild();
    await callGraphViewCtx.dispose();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

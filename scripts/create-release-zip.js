#!/usr/bin/env node

/**
 * Creates a release ZIP file for Reamo distribution.
 * Run with: node scripts/create-release-zip.js
 * Or via npm: npm run release
 */

import fs from 'fs';
import path from 'path';
import { execSync } from 'child_process';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Get version from package.json
const packageJson = JSON.parse(fs.readFileSync('package.json', 'utf8'));
const version = packageJson.version;

const RELEASE_NAME = `Reamo-v${version}`;
const RELEASE_DIR = path.join('releases', RELEASE_NAME);
const ZIP_FILE = path.join('releases', `${RELEASE_NAME}.zip`);

// Files to include in the release
const FILES = [
  { src: 'installer/Install_Reamo.lua', dest: 'Install_Reamo.lua' },
  { src: 'installer/Uninstall_Reamo.lua', dest: 'Uninstall_Reamo.lua' },
  { src: 'installer/Reamo_Startup.lua', dest: 'Reamo_Startup.lua' },
  { src: 'installer/README.txt', dest: 'README.txt' },
  { src: 'reamo.html', dest: 'reamo.html' },
  { src: 'scripts/Reamo_RegionEdit.lua', dest: 'Reamo_RegionEdit.lua' },
  { src: 'scripts/Reamo_MarkerEdit.lua', dest: 'Reamo_MarkerEdit.lua' },
  { src: 'scripts/Reamo_TimeSig.lua', dest: 'Reamo_TimeSig.lua' },
];

function main() {
  console.log(`Creating release: ${RELEASE_NAME}`);

  // Create releases directory
  fs.mkdirSync('releases', { recursive: true });

  // Remove old release dir if exists
  fs.rmSync(RELEASE_DIR, { recursive: true, force: true });
  fs.mkdirSync(RELEASE_DIR, { recursive: true });

  // Copy files
  let hasErrors = false;
  for (const file of FILES) {
    const srcPath = path.resolve(file.src);
    const destPath = path.join(RELEASE_DIR, file.dest);

    if (!fs.existsSync(srcPath)) {
      console.error(`  Missing file: ${srcPath}`);
      hasErrors = true;
      continue;
    }

    fs.copyFileSync(srcPath, destPath);
    console.log(`  Copied: ${file.dest}`);
  }

  if (hasErrors) {
    console.error('\nSome files were missing. Release may be incomplete.');
  }

  // Create ZIP
  // Remove old zip if exists
  if (fs.existsSync(ZIP_FILE)) {
    fs.unlinkSync(ZIP_FILE);
  }

  // Use system zip command (available on Mac/Linux, needs to be installed on Windows)
  try {
    execSync(`cd releases && zip -r "${RELEASE_NAME}.zip" "${RELEASE_NAME}"`, {
      stdio: 'inherit'
    });
  } catch (err) {
    console.error('\nFailed to create ZIP. Make sure "zip" command is available.');
    console.error('On Windows, install via: winget install GnuWin32.Zip');
    process.exit(1);
  }

  // Clean up directory (keep only ZIP)
  fs.rmSync(RELEASE_DIR, { recursive: true });

  console.log(`\nRelease created: ${ZIP_FILE}`);
  console.log('\nTo publish:');
  console.log('  1. git tag v' + version);
  console.log('  2. git push origin main --tags');
  console.log('\nOr upload manually to GitHub Releases.');
}

main();

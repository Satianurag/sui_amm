/**
 * SUI AMM Interactive Demo
 * 
 * This script demonstrates the complete AMM workflow on localnet.
 * Run with: npx ts-node interactive_demo.ts
 * 
 * Prerequisites:
 * 1. Start localnet: sui start --with-faucet
 * 2. Deploy contracts: ./01_deploy.sh
 * 3. npm install @mysten/sui.js
 */

import { getFullnodeUrl, SuiClient } from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';
import * as fs from 'fs';
import * as readline from 'readline';

// Load environment from deploy
const loadEnv = (): Record<string, string> => {
    try {
        const envContent = fs.readFileSync('.env', 'utf-8');
        const env: Record<string, string> = {};
        envContent.split('\n').forEach(line => {
            const [key, value] = line.split('=');
            if (key && value) env[key.trim()] = value.trim();
        });
        return env;
    } catch {
        console.error('❌ .env not found. Run ./01_deploy.sh first!');
        process.exit(1);
    }
};

const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

const prompt = (question: string): Promise<string> => {
    const rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout
    });
    return new Promise(resolve => {
        rl.question(question, answer => {
            rl.close();
            resolve(answer);
        });
    });
};

const printHeader = (title: string) => {
    console.log('\n' + '═'.repeat(60));
    console.log(`  ${title}`);
    console.log('═'.repeat(60) + '\n');
};

const printSuccess = (msg: string) => console.log(`✅ ${msg}`);
const printInfo = (msg: string) => console.log(`ℹ️  ${msg}`);
const printStep = (step: number, msg: string) => console.log(`\n[${step}] ${msg}`);

async function main() {
    console.log(`
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║              SUI AMM - Interactive Demo                       ║
║                                                               ║
║  This demo will execute real transactions on localnet         ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
    `);

    // Setup
    const env = loadEnv();
    const PACKAGE_ID = env.PACKAGE_ID;
    const POOL_REGISTRY = env.POOL_REGISTRY;
    const STATS_REGISTRY = env.STATS_REGISTRY;

    printInfo(`Package ID: ${PACKAGE_ID}`);
    printInfo(`Pool Registry: ${POOL_REGISTRY}`);

    // Connect to localnet
    const client = new SuiClient({ url: 'http://127.0.0.1:9000' });
    
    printHeader('DEMO MENU');
    console.log(`
    1. View Pool Registry Info
    2. View Pool Statistics  
    3. Check Gas Balance
    4. View All Pools
    5. Exit
    `);

    const choice = await prompt('Select option (1-5): ');

    switch (choice) {
        case '1':
            printHeader('Pool Registry Info');
            try {
                const registry = await client.getObject({
                    id: POOL_REGISTRY,
                    options: { showContent: true }
                });
                console.log(JSON.stringify(registry, null, 2));
            } catch (e) {
                console.error('Error fetching registry:', e);
            }
            break;

        case '2':
            printHeader('Pool Statistics');
            try {
                const stats = await client.getObject({
                    id: STATS_REGISTRY,
                    options: { showContent: true }
                });
                console.log(JSON.stringify(stats, null, 2));
            } catch (e) {
                console.error('Error fetching stats:', e);
            }
            break;

        case '3':
            printHeader('Gas Balance');
            const address = await prompt('Enter address (or press Enter for active): ');
            // Would need to get active address from sui client
            console.log('Use: sui client gas');
            break;

        case '4':
            printHeader('All Pools');
            printInfo('Querying pool registry...');
            // Query would go here
            console.log('Use: sui client object $POOL_REGISTRY');
            break;

        case '5':
            console.log('\nGoodbye! 👋\n');
            process.exit(0);

        default:
            console.log('Invalid option');
    }

    console.log('\n--- Demo Complete ---\n');
}

// Run
main().catch(console.error);

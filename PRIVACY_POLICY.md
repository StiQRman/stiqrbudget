# StiQRbudget Privacy Policy

**Effective Date:** November 19, 2026  
**Last Updated:** November 19, 2026  
**Website:** https://stiqrbudget.com  
**Developer Contact:** stiqrapps@gmail.com  

---

## 1. Our Core Privacy Philosophy: Zero-Knowledge

At StiQRbudget, your financial data belongs exclusively to you. 

Unlike traditional budgeting apps, **we do not want, collect, track, or sell your personal or financial information**. StiQRbudget was built from the ground up on a **Zero-Knowledge Architecture**, which means that all of your budgets, envelopes, transaction descriptions, amounts, and category balances are encrypted directly on your device before they ever touch the network.

**We cannot read your financial records, and we cannot sell your data to advertisers, data brokers, or financial institutions—because we do not have the keys to decrypt it.**

---

## 2. Cryptographic Security Standards

Your financial data is protected by industry-standard, **Post-Quantum Hybrid Encryption (ML-KEM-768 + X25519 + AES-256-GCM)** end-to-end client-side cryptography:
* **AES-256-GCM (Authenticated Encryption):** All transaction records, envelope names, notes, and balance allocations are encrypted on your physical device using AES-256-GCM.
* **Deterministic Key Derivation (PBKDF2-SHA256 & FIPS 203 ML-KEM-768):** When you sign in, your master cryptographic keys, Data Encryption Keys (DEKs), and NIST FIPS 203 ML-KEM-768 post-quantum keypairs are derived locally and deterministically on your device using 60,000 rounds of PBKDF2 with SHA-256 and unique cryptographic salts.
* **Ed25519 Digital Signatures:** Cloud requests and peer-to-peer sync operations are cryptographically signed using Ed25519 keypairs. The server only validates signatures to prevent unauthorized writes; it cannot inspect the payload.
* **Post-Quantum Hybrid Key Exchange (ML-KEM-768 + X25519):** Multi-device synchronization and peer collaboration protect shared budget keys using hybrid NIST FIPS 203 ML-KEM-768 key encapsulation combined with X25519 Diffie-Hellman key exchange, with automatic zero-action upgrades on sync.
* **Client-Isolated Keys:** Your private decryption keys never leave your device in unencrypted form. Neither our servers, our infrastructure providers, nor any third party have access to your keys.

---

## 3. Information We Collect (and What We Don't)

### What We NEVER Collect:
* **No Bank Account Credentials:** We never ask for your bank login, account numbers, or routing numbers. We do not use third-party bank scrapers (e.g., Plaid, Yodlee, MX).
* **No Financial Details:** We cannot view your income, account balances, spending habits, transaction history, or category titles.
* **No Ad Tracking or Device Profiling:** We do not embed ad SDKs, tracking pixels, or cross-app tracking beacons.

### What We Process (Encrypted / Minimal Metadata):
* **Account Identifier:** Your email address (normalized and hashed) is used solely for account identification and authentication token routing.
* **Encrypted Blobs:** When multi-device sync is active, our decentralized sync relay (StiQRcloud) stores encrypted ciphertexts. To our servers, your data appears as random, unreadable strings of characters (`tc:enc:v1:...`).
* **Basic Telemetry / Crash Diagnostics:** If enabled by your operating system (e.g., Google Play crash reports), non-identifying technical diagnostic info (e.g., OS version, crash stack traces) may be received to fix app bugs.

---

## 4. In-App Subscriptions & Billing

StiQRbudget offers optional paid subscriptions (e.g., \$1/month or \$10/year) for power features like unlimited envelopes, multi-year cloud sync archives, and advanced reports.
* All financial transactions for subscriptions are processed directly and securely by the **Google Play Store**.
* We never see or store your credit card, debit card, or billing information.
* Google Play provides us only with an anonymous purchase token to verify your subscription status.

---

## 5. Data Sovereignty & Portability (Free CSV Export)

You have full ownership of your data at all times. 
* **Free Export:** StiQRbudget provides an in-app **Export to CSV** feature available to all users at zero cost. You can export your unencrypted budgets, envelopes, and transaction history to standard spreadsheets anytime.
* **Deletion:** You can delete your envelopes, transactions, or account directly from the app. Deleting your account purges your encrypted blobs from our sync relays.

---

## 6. Children's Privacy

StiQRbudget is not directed to individuals under the age of 13. We do not knowingly collect personal information from children.

---

## 7. Legal Disclaimers & Limitation of Liability

* **Educational / Budgeting Tool Only:** StiQRbudget is a software tool for personal budget planning and expense tracking. It does not provide financial, investment, legal, or tax advice. You are solely responsible for managing your financial affairs.
* **No Warranty:** The software is provided "as is" and "as available", without warranty of any kind, express or implied.
* **Responsibility for Keys / Passwords:** Because StiQRbudget is zero-knowledge, **if you lose your account password and master credentials, we cannot reset them or recover your encrypted data for you**. Always keep a secure backup of your credentials.

---

## 8. Changes to This Policy

We may update this Privacy Policy from time to time to reflect product updates or legal requirements. Material changes will be noted with an updated "Effective Date" at the top of this document.

---

## 9. Contact Us

If you have questions, feedback, or concerns regarding your privacy or this policy, please reach out to us at:
* **Email:** stiqrapps@gmail.com

# StiqrBudget

A modern, responsive, offline-first personal finance and envelope budgeting application built with Flutter. Features zero-friction income allocation, intelligent transaction ledgers, interactive spending reports, and cloud synchronization powered by StiQRcloud.

---

## Key Features

- **Envelope Budgeting**:
  - Assign money into custom category envelopes with configurable allocation strategies (fixed per check, percentage, target balance).
  - Visual deficit alerts and one-tap deficit transfers to rebalance envelopes.
- **Smart Income Allocator**:
  - Automatically calculate and distribute paychecks across active budget categories.
  - Preview allocation balances before committing.
- **Comprehensive Transaction Ledger**:
  - Track Income, Expenses, and Category Transfers with real-time balance calculations.
  - Interactive search, category filtering, and transaction detail management.
- **Spending Reports & Analytics**:
  - Dynamic spending breakdown by category with customizable time intervals.
  - Interactive validation and spending pacing indicators.
- **Security & Privacy**:
  - Biometric authentication and local lock protection.
  - Direct, private sync with self-hosted StiQRcloud backend.
- **Cross-Platform & In-App Updates**:
  - Production-grade Flutter Web and Android APK builds.
  - Integrated APK download manager and release notification system.

---

## Infrastructure & Endpoints

- **Live Web App**: [https://stiqrbudget.com](https://stiqrbudget.com)
- **StiQRcloud API**: [https://stiqrcloud.stiqrnotes.com](https://stiqrcloud.stiqrnotes.com)
- **GitHub Repository**: [https://github.com/StiQRman/stiqrbudget](https://github.com/StiQRman/stiqrbudget)


---

## Release & Deployment Pipeline

StiqrBudget utilizes an automated deployment pipeline (`deploy_all.py`):

```bash
# Auto-bump patch version, deploy web to Pi Nginx, build APK & publish release
python3 deploy_all.py --changelog "Your release notes here"

# Or specify a version explicitly
python3 deploy_all.py --version 1.0.2 --changelog "Added spending reports and UI enhancements"
```

---

## Local Development

Run on Chrome / Web:
```bash
flutter run -d chrome
```

Run test suite:
```bash
flutter test
```


# Final Accounting Audit — Treasury Reversal (Sales Lifecycle)

Branch: `fix/treasury-reversal`
Target: `CairoTech_v6.html` (SPA)
Date: 2026-08-02

## 1. Scope & Method

Audited **every function that modifies the Treasury balance** (`DB.cashFlow` via `addCashEntry`)
and verified every **create / edit / delete** path has a correct, exact reverse operation for all
payment methods supported by the app.

Supported payment methods (one payment per invoice — no mixed payments exist in the app):
`cash`, `instapay`, `vodafone`, `fawry`, `installment`.

Verification was done end-to-end in a real Chromium browser (Playwright, `file://`), logging in as
`Owner`, resetting the DB to a clean state with a `100,000` cash opening balance, and asserting the
Treasury returns **exactly** to its pre-state after each delete/undo cycle.

## 2. Findings & Fixes

### 2.1 Sale invoice lifecycle — already correct (committed in `1016e1c`)
- **POS cash** create (`completeSale`) → treasury +total; delete → `-total` exact.
- **POS ajel** create → full amount on spot (partial / no-partial); delete reverses it.
- **Installment** create → `getSaleInvoiceInstallment` computes monthly splits + down payment;
  delete reverses all splits + down payment; collected monthly installment on delete is also reversed.
- **Quick sale** and **new sale** (`saveNewSaleInvoice` + `saveEditSaleInvoice`) reversible for all
  5 methods, including method→method edits.
- **Sales return** create (`saveReturn` `action === 'refund'`) → `out`; delete/update reverse via `in`.
- Entry-count sanity checks (no orphan/duplicate entries) all pass.

### 2.2 NEW BUG — purchase return treasury never reversed (FIXED in this commit)
`saveReturn` for purchase invoices uses `action === 'supplier_refund'` and adds the refund as a
cash **`in`** entry. However `deleteReturn` and `updateReturn` only reversed entries where
`action === 'refund'`, leaving an **orphan Treasury credit** whenever a purchase return was deleted
or edited.

Verified live before fix: purchase return `+50,000` → delete → Treasury stayed `150,000` instead of
returning to `100,000`.

Fix: `deleteReturn` / `updateReturn` now reverse by direction per type —
- Sale return (`refund`): was `out` → reverse with `in`.
- Purchase return (`supplier_refund`): was `in` → reverse with `out`.

Also fixed `updateReturn` to preserve `r.refund` for purchase returns (it previously zeroed it).

Verified after fix: create `150,000` → delete → `100,000` exact. ✅

### 2.3 NEW BUG — deleting an expense left an orphan Treasury debit (FIXED in this commit)
`saveExpense` records the cost as a cash `out` entry, but `deleteExpense` removed only the record,
leaving the `out` entry permanently in the Treasury.

Verified live before fix: expense `-30,000` → delete → Treasury stayed `70,000`.

Fix: `deleteExpense` now adds a matching reverse `in` entry before removing the record.

Verified after fix: create `70,000` → delete → `100,000` exact. ✅

### 2.4 NEW BUG — deleting a voucher left an orphan Treasury entry (FIXED in this commit)
`saveVoucher` adds `in` for a receipt voucher and `out` for a payment voucher, but `deleteVoucher`
removed only the record.

Verified live before fix: receipt voucher `+20,000` → delete → Treasury stayed `120,000`.

Fix: `deleteVoucher` now adds the opposite-direction entry before removing the record.

Verified after fix: create `120,000` → delete → `100,000` exact. ✅

## 3. Test Results (all green)

| Suite | Assertions | Result |
|---|---|---|
| `audit_lifecycle_test.js` (full sales lifecycle, all methods) | 125 | ✅ PASSED |
| `regression_test.js` (core) | 49 | ✅ PASSED |
| `regression_edit_test.js` (edit method→method) | 11 | ✅ PASSED |
| `regression_purchase_test.js` (purchase + returns) | 8 | ✅ PASSED |
| Post-fix live repro: purchase-return delete / expense delete / voucher delete | 3 | ✅ PASSED |

**Total: 196 assertions, 0 failures. JS syntax check OK. No page errors.**

## 4. Conclusion

Every Treasury mutation produced by sales invoices, purchase/sales returns, expenses, and vouchers is
now fully reversible across all payment methods. No accounting inconsistency remains. Branch is
approved for merge.

## 5. Related files
- `CairoTech_v6.html` — fixes in `deleteReturn`, `updateReturn`, `deleteExpense`, `deleteVoucher`.
- `TREASURY_REVERSAL_FIX_REPORT.md` — earlier sales-invoice lifecycle fix report.

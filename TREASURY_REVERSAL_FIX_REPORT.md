# TREASURY REVERSAL FIX — Sales Invoice Deletion / Edit

**Branch:** `fix/treasury-reversal`
**File:** `CairoTech_v6.html`
**Scope:** Treasury balance correctness when a Sales Invoice is deleted or edited.

---

## 1. Bug Summary

Deleting a **Sales Invoice** did not correctly reverse the Treasury balance, and in some
cases drove Treasury to a **negative balance**. Editing a Sales Invoice also failed to
reverse prior cash movements in certain payment modes.

## 2. Root Causes

### Root Cause 1 — Installment invoices reversed the FULL total on delete

In `deleteSaleInvoice()`, the treasury-reversal branch keyed off `invoiceType === 'cash'`.
A sale made with `payment === 'installment'` (which records `invoiceType = 'cash'` at
creation, adding only the **down payment** to Treasury) fell into that branch and
reversed the **full invoice total**. Example:

- Invoice total: 500,000 EGP, down payment: 100,000 EGP
- Creation adds +100,000 to Treasury
- Deletion removed −500,000 → Treasury became **−300,000 EGP** (negative)

Additionally, the linked `DB.installments` record was left **orphaned** after deletion.

### Root Cause 2 — Editing an old installment invoice never reversed its down payment

In `saveEditSaleInvoice()`, `oldCashAmount` was computed as `0` whenever the old
payment method was `installment`, so the previously-added down payment was never
reversed when the invoice was edited (e.g. switched to cash/ajel).

### Root Cause 3 — Installment records had no link to the invoice

`DB.installments` records pushed in `completeSale()` carried no `invoiceId`, making it
impossible to reliably locate and remove the matching installment record on delete/edit.

## 3. Fixes Applied

### 3.1 `completeSale()` — link installment record to the invoice
- Save the down payment on the invoice: `invoice.installmentDownPayment = downPayment;`
- Store `invoiceId` on the pushed `DB.installments` record.

### 3.2 New helper `getSaleInvoiceInstallment(invoiceId, customer, total)`
- Resolves the linked installment record by `invoiceId`.
- Legacy fallback: match by `customer + total` (supports records created before the fix).

### 3.3 `deleteSaleInvoice()` — precise treasury reversal
- **Installment** (`inv.payment === 'installment'`): reverse only the **down payment**
  (`addCashEntry('out', downPayment, 'cash', …)`) and **remove the linked installment record**.
- **Cash** (`inv.invoiceType === 'cash'`): reverse `inv.total` (unchanged behavior).
- **Ajel / credit** (`inv.invoiceType === 'ajel'`): reverse `inv.paidAmount` (unchanged behavior).

### 3.4 `saveEditSaleInvoice()` — reverse old installment down payment on edit
- Detect `oldWasInstallment`; reverse the old installment down payment (method `cash`,
  matching how it was added at creation).
- When switching from installment → non-installment, **delete the linked installment record**.

## 4. Regression Tests

All tests run in a headless Chromium (Playwright) against the fixed file, after
logging in as `Owner`/`RTX3080`, with a clean DB state (opening balance 100,000 EGP).

### 4.1 Core suite — 11 scenarios, 49 assertions (PASS)
| # | Scenario | Key checks |
|---|----------|-----------|
| 1 | CASH (POS) → delete | Treasury 600k → 100k; invoice/profit removed |
| 2 | INSTAPAY cash → delete | InstaPay 500k → 0; total Treasury 100k |
| 3 | AJEL no partial → delete | Treasury unchanged 100k; outstanding restored |
| 4 | AJEL partial 100k → delete | Treasury 200k → 100k; outstanding restored |
| 5 | INSTALLMENT → delete | Treasury 200k (down only) → 100k; installment record removed |
| 6 | LEGACY installment (no link) → delete | Down payment reversed via fallback; record removed |
| 7 | QUICK SALE → delete | Treasury 600k → 100k |
| 8 | NEW SALE (saveNewSaleInvoice) → delete | Treasury 600k → 100k |
| 9 | INVOICE EDIT cash→ajel | Old cash reversed; type changed |
| 10 | Dashboard/Reports/Archive/Treasury DOM | All surfaces update on create + delete |
| 11 | Inventory + Serials restoration | Serial back to available; saleInvoiceId null |

### 4.2 Purchase + Returns suite — 8 assertions (PASS)
- Purchase POS create/delete: Treasury 100k → −50k → 100k; stock +1 → 0.
- Purchase return (supplier_refund): Treasury +100k; return record created.
- Sales return (refund): Treasury −80k.

### 4.3 Edit suite — 11 assertions (PASS)
- Installment → cash edit: old down 100k reversed + new cash 500k → 600k; installment
  record removed.
- Installment → installment (amount change): Treasury unchanged; installment preserved.
- Ajel partial → cash edit: partial 100k reversed + new cash 500k → 600k.

**Total: 68 assertions, 0 failures.** No JS page errors (only an unrelated
`favicon.ico` 404 console notice).

## 5. Files Changed

- `CairoTech_v6.html` — 97 insertions, 31 deletions (only the four functions above).

## 6. Verification Commands

```powershell
node "C:\Users\hp\AppData\Local\Temp\opencode\regression_test.js"
node "C:\Users\hp\AppData\Local\Temp\opencode\regression_purchase_test.js"
node "C:\Users\hp\AppData\Local\Temp\opencode\regression_edit_test.js"
```

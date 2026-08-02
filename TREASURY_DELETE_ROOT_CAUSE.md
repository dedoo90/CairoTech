# Treasury Delete Root Cause Report

Branch: `fix/treasury-reversal`
Target: `CairoTech_v6.html` (SPA, single file)
Date: 2026-08-02
Report type: Root-cause analysis of the "delete sale invoice leaves Treasury unchanged / inconsistent" defect, reproduced manually in a real browser.

## 1. Manual reproduction of the reported symptom

1. Reset the app DB to a clean state with a `100,000` cash opening entry (only in the Treasury).
2. Create a **POS installment sale** (`إصدار بيع جديد V2`) for `500,000` with a `100,000` down payment
   → Treasury shows `200,000` (`opening 100,000` + `down payment 100,000`).
3. Pay one **monthly installment** of `66,666.67` (`قسيط`) via the installments screen
   → Treasury shows `266,666.67`.
4. **Delete the sale invoice** from the Invoices list
   → Treasury stayed **`166,666.67`** (should be back to `100,000`).

Same symptom with a plain cash sale before the earlier fix: create `100,000 → 600,000`, delete →
stayed `600,000` (nothing reversed).

## 2. Exact code path

### 2.1 UI delete function (what the user clicks)

- Invoices list is rendered by `renderInvoices`; the delete button is emitted at line **~8855**:
  ```js
  <button class="btn btn-sm btn-danger" onclick="deleteSaleInvoice('${inv.id}')">حذف</button>
  ```
  guarded by `can('deleteData')`.
- The handler is **`deleteSaleInvoice(id)`** at line **9324**. (No other sale-invoice delete
  handler exists in the inventory UI.)

### 2.2 Treasury mutation function (what changes the balance)

- The **only** Treasury store is `DB.cashFlow`. Every mutation goes through
  **`addCashEntry(type, amount, method, desc, meta)`** at line **3761**, which pushes an entry and
  recomputes `balance`.

Three places mutate the Treasury for a sale invoice:
| Operation | Function | Line |
|---|---|---|
| Create | `completeSale` / `saveNewSaleInvoice` / `saveQuickSale` | `addCashEntry('in', …)` |
| Collect monthly installment | `saveInstallmentPayment` | `addCashEntry('in', amount, method, desc, {refId, refType})` |
| Delete | `deleteSaleInvoice` | reversal `addCashEntry('out', …)` |

## 3. Root cause

`deleteSaleInvoice` did **not** mirror exactly what creation wrote to the Treasury:

1. **Cash / ajel invoices** (fixed in earlier commit `1016e1c`): the reverse amounts now match
   creation exactly (`total` for cash, `paidAmount` for ajel).
2. **Installment invoices — monthly payments were orphaned (this report):**
   - Creation only credits the **down payment** (`in|cash`), and the customer's paid monthly
     installments are credited as **separate** `in` entries tagged with
     `{ refId: inst.id, refType: 'installment-payment' }` (line **6255**).
   - Deletion reversed **only the down payment**, then removed the installment record. The collected
     monthly payments stayed in `DB.cashFlow` forever as orphan income → Treasury never returned to
     its pre-state.
3. **Edit installment → other method (this report):** `saveEditSaleInvoice` reversed only the down
   payment when converting away from installment, leaving the same orphan entries, and deleted the
   installment record.

## 4. Code changes

### 4.1 Tag monthly installment payments (line 6255)
`saveInstallmentPayment` now forwards a 5th `meta` argument to `addCashEntry`, tagging the entry so it
can be identified and reversed later:
```js
addCashEntry('in', amount, method, `قسيط ${inst.customer}`, { refId: inst.id, refType: 'installment-payment' });
```

### 4.2 `addCashEntry` accepts and stores the tag (line 3761)
```js
function addCashEntry(type, amount, method, desc, meta) {
  ...
  if (meta && typeof meta === 'object') {
    Object.keys(meta).forEach(k => { entry[k] = meta[k]; });
  }
  ...
}
```

### 4.3 New helper `reverseInstallmentTreasury(inst, reason)` (line 9312)
Reverses the down payment **plus every tagged collected monthly payment**:
```js
function reverseInstallmentTreasury(inst, reason) {
  if (!inst) return;
  const downPayment = Number(inst.downPayment || 0);
  if (downPayment > 0) {
    addCashEntry('out', downPayment, 'cash', `إلغاء مقدم تقسيط - ${reason || inst.customer}`);
  }
  DB.cashFlow.filter(c => c.refId === inst.id && c.refType === 'installment-payment' && c.type === 'in')
    .forEach(pc => {
      addCashEntry('out', pc.amount || 0, pc.method || 'cash', `إلغاء قسط مدفوع - ${reason || inst.customer}`);
    });
}
```

### 4.4 `deleteSaleInvoice` (line 9324, installment branch)
Replaces the down-payment-only reversal with the helper, then removes the installment record:
```js
if (inv.payment === 'installment') {
  const inst = getSaleInvoiceInstallment(id, inv.customer, inv.total);
  if (inst) {
    reverseInstallmentTreasury(inst, `فاتورة بيع #${id} - ${inv.customer}`);
    const instIdx = DB.installments.indexOf(inst);
    if (instIdx !== -1) DB.installments.splice(instIdx, 1);
  } else {
    const downPayment = Number(inv.installmentDownPayment != null ? inv.installmentDownPayment : 0);
    if (downPayment > 0) {
      addCashEntry('out', downPayment, 'cash', `إلغاء مقدم تقسيط لفاتورة بيع #${id} - ${inv.customer}`);
    }
  }
}
```

### 4.5 `saveEditSaleInvoice` (line 9491, installment → other)
When converting away from installment, reverses the full contract (down + collected monthly) via the
helper and suppresses the old down-payment-only reversal to avoid a double reverse:
```js
const convertingAwayFromInstallment = oldWasInstallment && newPayment !== 'installment' && !!oldInst;
...
if (convertingAwayFromInstallment) {
  reverseInstallmentTreasury(oldInst, `تعديل فاتورة بيع #${id} - ${inv.customer}`);
}
```

## 5. Proof — end-to-end UI reproduction (Playwright, real Chromium)

Repro scripts: `ui_inst_collect_repro.js`, `ui_edit_delete_repro.js`, `matrix_test.js` (in the temp
test workspace). All drive the **real UI** (`file://`), log in as `Owner`, reset the DB with a
`100,000` opening balance, and click the actual buttons/`deleteSaleInvoice` used by the user.

### 5.1 Delete after collecting a monthly installment (the reported bug)
```
CREATE:            sum=200000            inst={down:100000, remaining:400000, monthly:66666.67}
AFTER MONTHLY PAY: sum=266666.67        inst={paid:1}
DELETE:            sum=100000            installments=0          ✅ (was 166666.67 before fix)
```

### 5.2 Edit installment → cash, then delete
```
EDIT  installment->cash then DELETE:  beforeEdit=266666.67 afterEdit=600000 delete=100000  ✅
EDIT  cash->installment then DELETE:  beforeEdit=600000    afterEdit=100000 delete=100000  ✅
```

### 5.3 Create+delete matrix — all payment methods (10/10 PASS)
```
POS cash/cash, POS ajel+paid, POS installment, POS instapay, POS vodafone, POS fawry,
NEWSALE cash/cash, NEWSALE ajel+paid, QUICK cash, QUICK ajel
→ create moves Treasury up, delete returns it to exactly 100000 for every scenario.
```

### 5.4 Full regression suites
| Suite | Assertions | Result |
|---|---|---|
| `audit_lifecycle_test.js` (full sales lifecycle, all methods) | 125 | ✅ PASSED |
| `regression_test.js` (core) | 49 | ✅ PASSED |
| `regression_edit_test.js` (edit method→method) | 11 | ✅ PASSED |
| `regression_purchase_test.js` (purchase + returns) | 8 | ✅ PASSED |
| `matrix_test.js` create/delete matrix | 10 | ✅ PASSED |

**Total: 203 assertions, 0 failures. JS syntax check OK. No page errors.**

## 6. Conclusion

Deleting (or editing away) a sale invoice now reverses **every** Treasury entry it created — including
collected monthly installment payments — so the Treasury returns exactly to its pre-sale state in all
payment scenarios. No orphan entries remain.

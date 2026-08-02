# REAL UI DELETE TRACE — فاتورة بيع / الخزنة

**التاريخ:** 2026-08-02
**الفرع:** `fix/treasury-reversal`
**الملف:** `CairoTech_v6.html`

---

## 1) مسار الحدث من الواجهة إلى الدالة (UI Event → Function Trace)

الزر الوحيد لحذف فاتورة بيع في الواجهة يُرسم داخل `renderInvoices()`:

```
#invoicesTbody tr  ←  rows of DB.saleInvoices
  └── <button class="btn btn-sm btn-danger"
        onclick="deleteSaleInvoice('INV-000001')">
        🗑️
      </button>
```

نقرة المستخدم على الزر تولّد:

```
click → onclick="deleteSaleInvoice('INV-000001')"
      → deleteSaleInvoice(id)          ← الدالة الوحيدة المسئولة عن الحذف
```

- يوجد **زر حذف واحد فقط** لفاتورة البيع (تحقق شامل من كل الأزرار في الملفين المصلّح والمنشور).
- الحذف محمي بـ `can('deleteData')` على مستوى الرسم، والدالة نفسها تؤكد عبر `confirm()`.

---

## 2) Call Stack الكامل من لحظة النقر

```
[click على زر الحذف]
  deleteSaleInvoice('INV-000001')
    ├── confirm('هل تريد حذف فاتورة البيع #INV-000001 نهائيًا؟')
    ├── (inv.items).forEach → استرجاع المخزون / السيريالات
    ├── reverseInstallmentTreasury(inst, desc)      ← (المصلّح فقط)
    │     └── addCashEntry('out', downPayment, 'cash', desc)
    │     └── addCashEntry('out', collectedMonthly, 'cash', desc) لكل قسط مدفوع
    ├── DB.saleInvoices = filter(...)
    ├── saveDB()
    └── renderInvoices(); renderTreasury(); renderDashboard(); renderReports()
          └── renderTreasury():
                total = cash + instapay + vodafone + fawry   ← المجموع المعروض
```

---

## 3) مسار تحديث الخزنة (Treasury Update Path)

- الخزنة بالكامل = `DB.cashFlow`، وتُعدَّل فقط عبر `addCashEntry(type, amount, method, desc, meta)`.
- `renderTreasury()` يعرض المجموع الحقيقي على الشاشة كالتالي:

```js
const total = cash + instapay + vodafone + fawry;   // طرق الدفع الأربعة فقط
```

أي أن **أي حركة بخصم غير هذه الطرق الأربع لا تظهر في رصيد الخزنة المعروض**.

---

## 4) تشخيص سبب العطل (Root Cause) — انحراف مسار الواجهة عن المسار المختبر

### المسار المختبر مسبقاً (اختبارات automations):
أنشأت الاختبارات فاتورة **كاش/كاش** (`invoiceType='cash'` + `payment='cash'`)،
والحذف في هذه الحالة كان يعكس الإجمالي بطريقة `cash` → يعمل بشكل صحيح في **كلا** الملفين.

### المسار الحقيقي الذي استخدمه المستخدم (انحراف):
المستخدم ينشئ فاتورة نوعها **كاش** لكن **طريقة الدفع = تقسيط** مع مقدم
(`saleIssueType='cash'` + `saleIssuePayment='installment'` + مقدم 200,000).

عند الإنشاء في `completeSale()`:

```js
if (paymentType !== 'installment' && invoiceType === 'cash') { ... } // يُتخطى
...
if (paymentType === 'installment') {
  if (downPayment > 0) addCashEntry('in', downPayment, 'cash', 'مقدم تقسيط ...'); // +200000 ظاهرة
}
```

### الحذف في النسخة المنشورة (main / deployed) — `deleteSaleInvoice` القديمة:

```js
if (inv.invoiceType === 'cash' && inv.total > 0) {
  addCashEntry('out', inv.total, inv.payment || 'cash', ...);
  // inv.payment = 'installment'  ← طريقة غير معروضة في الخزنة!
  // inv.total   = 500000         ← يعكس الإجمالي كاملاً وليس المقدم فقط
}
```

النتيجة: الحركة تُكتب بطريقة `'installment'`، فتستبعدها `renderTreasury` من المجموع المعروض
→ **رصيد الخزنة يبقى زائداً بعد الحذف** (وهذا بالضبط ما رآه المستخدم).

---

## 5) الإصلاح (Fix) في `fix/treasury-reversal`

في `deleteSaleInvoice` أُضيف فرع أولي يعترض فواتير التقسيط قبل فحص `invoiceType`:

```js
if (inv.payment === 'installment') {
  const inst = getSaleInvoiceInstallment(id, inv.customer, inv.total);
  if (inst) {
    reverseInstallmentTreasury(inst, `فاتورة بيع #${id} - ${inv.customer}`);
    DB.installments.splice(DB.installments.indexOf(inst), 1);
  } else {
    const down = Number(inv.installmentDownPayment != null ? inv.installmentDownPayment : 0);
    if (down > 0) addCashEntry('out', down, 'cash', `إلغاء مقدم تقسيط ...`);
  }
} else if (inv.invoiceType === 'cash' && inv.total > 0) {
  addCashEntry('out', inv.total, inv.payment || 'cash', ...);
} else if (inv.invoiceType === 'ajel' && (inv.paidAmount || 0) > 0) {
  addCashEntry('out', inv.paidAmount, inv.payment || 'cash', ...);
}
```

- `reverseInstallmentTreasury(inst, desc)` تعكس **المقدم فقط** + **الأقساط الشهرية المدفوعة**
  (المضافة عبر `saveInstallmentPayment` الموسومة بـ `{refId, refType}`)، كلها بطريقة `cash`.
- `saveInstallmentPayment` بات يوسم حركات الأقساط بـ `{refId, refType: 'installment-payment'}`
  و`addCashEntry` يدعم معامل خامس `meta` لتخزين هذه الوسوم.
- نفس المعالجة أُضيفت لمسار التعديل من تقسيط إلى غير تقسيط في `saveEditSaleInvoice`.

---

## 6) التحقق اليدوي الحقيقي (Real-Click Playwright) — برهان 100000 == 100000

التجربة نُفِّذت بنقرات حقيقية 100% (تسجيل دخول حقيقي، نقرة على كارت المنتج، إتمام البيع،
تحديد التقسيط، نقر زر الحذف، وتأكيد `confirm`)، على كلا الملفين.

**السيناريو:** POS → إضافة منتج 500,000 → إتمام → نوع=كاش، دفع=تقسيط، مقدم=200,000 → حذف.

### النسخة المنشورة (main / deployed) — BUG:

```
createSum=300000  deleteSum=300000   ← الخزنة تبقى زائدة (العطل)
الحركات:
  {out, 500000, method='installment', "إلغاء فاتورة بيع #INV-000001"}  ← غير معروضة
  {in,  200000, method='cash',        "مقدم تقسيط - عميل نقدي"}
  {in,  100000, method='cash',        "opening"}
```

### النسخة المصلّحة (fix/treasury-reversal) — FIXED:

```
createSum=300000  deleteSum=100000   ← رصيد ما قبل الإنشاء = رصيد ما بعد الحذف ✓
الحركات:
  {out, 200000, method='cash', "إلغاء مقدم تقسيط - فاتورة بيع #INV-000001"}  ← معروضة
  {in,  200000, method='cash', "مقدم تقسيط - عميل نقدي"}
  {in,  100000, method='cash', "opening"}
```

### برهان المساواة (المطلوب من المستخدم):

```
رصيد قبل الإنشاء   = 100,000
رصيد بعد الإنشاء   = 300,000   (زاد بمقدار المقدم 200,000)
رصيد بعد الحذف     = 100,000   ==  رصيد قبل الإنشاء  ✓
```

### مصفوفة شاملة بنقرات حقيقية (المجلد Temp/opencode/ui_real_matrix.js)

كل سيناريوهات الكاش تمر في الملفين المصلّح والمنشور (لا انحراف لفاتورة الكاش البحتة):

| المسار | FIXED create | FIXED delete | MAIN create | MAIN delete |
|---|---|---|---|---|
| POS cash/cash | 600000 | 100000 ✓ | 600000 | 100000 ✓ |
| New Sale V2 cash/cash | 600000 | 100000 ✓ | 600000 | 100000 ✓ |
| Quick Sale cash | 600000 | 100000 ✓ | 600000 | 100000 ✓ |
| POS cash/installment | 300000 | 100000 ✓ | 300000 | **300000 ✗** |

---

## 7) الخلاصة

- دالة الحذف الحقيقية من الواجهة هي `deleteSaleInvoice(id)` (السطر ~9324 في المصلّح، ~9243 في main).
- انحراف المستخدم سببه فاتورة نوعها **كاش** بطريقة دفع **تقسيط**: الإنشاء يضيف المقدم
  بطريقة `cash` (ظاهر)، بينما الحذف القديم كان يعكس الإجمالي بطريقة `installment` (غير ظاهر).
- الإصلاح يعترض فرع التقسيط ويعكس المقدم + الأقساط المدفوعة بطريقة `cash`.
- التحقق الحقيقي أثبت: بعد الحذف رصيد الخزنة = 100,000 == قبل الإنشاء.

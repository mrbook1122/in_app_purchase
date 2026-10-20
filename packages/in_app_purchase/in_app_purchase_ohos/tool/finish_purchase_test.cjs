// Runs the actual ArkTS handler with mocked IAP/Flutter services. This verifies
// control flow, not ArkTS compilation or device behavior. Set IAP_TYPESCRIPT to
// the TypeScript module bundled with your HarmonyOS SDK, or install TypeScript.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.IAP_TYPESCRIPT || 'typescript');
const source = fs.readFileSync(path.join(__dirname,
  '../ohos/src/main/ets/components/MethodCallHandlerImpl.ets'), 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
}).outputText;
const PRODUCT = 'subscription.monthly';
const ORDER = 'order-123';
const TOKEN = 'test-token';
const TYPE = 2;
function setup({ pages = [], finishError, syncError, cache = true } = {}) {
  const queries = [], finishes = [], updates = [];
  const iap = {
    ProductType: { CONSUMABLE: 0, NONCONSUMABLE: 1, AUTORENEWABLE: TYPE },
    PurchaseQueryType: { UNFINISHED: 1 },
    IAPErrorCode: { PURCHASE_FINISHED: 1001860053 },
    queryPurchases: async (_, args) => {
      queries.push(args);
      const page = pages.shift();
      if (page instanceof Error) throw page;
      return page || { purchaseDataList: [] };
    },
    finishPurchase: (_, args) => {
      finishes.push(args);
      if (syncError) throw syncError;
      return finishError ? Promise.reject(finishError) : Promise.resolve();
    },
  };
  const exports = {};
  vm.runInNewContext(compiled, {
    exports,
    require: (name) => {
      switch (name) {
        case '@kit.IAPKit': return { iap };
        case '@kit.ArkTS': return { HashMap: Map };
        case '@ohos/flutter_ohos': return { Log: { i() {}, e() {} } };
        case './MethodNames': return { MethodNames: {} };
        case './ProductType': return { ProductType: [0, 1, TYPE] };
        case '../common/JWTUtil': return { JWTUtil: { decodeJwtObj: (jwt) => jwt } };
        case './TransactionState': return { TransactionState: { purchased: 1 } };
        case '../common/TsUtil': return { ObjToMap: (obj) => new Map(Object.entries(obj)) };
        default: throw new Error(`Unexpected runtime import: ${name}`);
      }
    },
  });
  const handler = new exports.MethodCallHandlerImpl({}, {
    invokeMethod: (_, value) => updates.push(value),
  });
  handler.setContext({});
  if (cache) handler.productDetailsMap.set(PRODUCT, { type: TYPE });
  return { handler, queries, finishes, updates, iap };
}
function credential(extra = {}) {
  return { purchaseOrderId: ORDER, purchaseToken: TOKEN, productType: TYPE, productId: PRODUCT, ...extra };
}
async function complete(env, data = credential(), args = {}) {
  const replies = [];
  const result = {
    success: (value) => replies.push({ ok: true, value }),
    error: (code, message) => replies.push({ ok: false, code, message }),
  };
  await env.handler.iapFinishPurchase({ args: new Map(Object.entries({
    productIdentifier: PRODUCT, transactionIdentifier: ORDER,
    verificationData: data === undefined ? undefined : typeof data === 'string' ? data : JSON.stringify(data),
    ...args,
  })) }, result);
  assert.equal(replies.length, 1, 'must reply exactly once');
  return replies[0];
}
function purchase({ orderId = ORDER, productId = PRODUCT, type = TYPE, tokenInOrder = false } = {}) {
  const order = { purchaseOrderId: orderId, productId, purchaseToken: TOKEN };
  return JSON.stringify(type === TYPE ? {
    type, jwsSubscriptionStatus: JSON.stringify({ lastSubscriptionStatus: {
      lastPurchaseOrder: order, ...(tokenInOrder ? {} : { purchaseToken: TOKEN }),
    } }),
  } : { type, jwsPurchaseOrder: JSON.stringify(order) });
}
test('complete exact credential without cache or querying unfinished orders', async () => {
  const env = setup({ cache: false });
  assert.equal((await complete(env)).ok, true);
  assert.equal(env.queries.length, 0);
  assert.equal(env.finishes.length, 1);
  assert.equal(env.finishes[0].purchaseOrderId, ORDER);
  assert.equal(env.finishes[0].purchaseToken, TOKEN);
});
test('already finished is idempotent success', async () => {
  const env = setup({ finishError: { code: 1001860053, message: 'already finished' } });
  assert.equal((await complete(env)).ok, true);
});
for (const code of [1001860005, 1001860052, 1001860002]) {
  test(`preserves real IAP failure ${code}`, async () => {
    const env = setup({ finishError: { code, message: 'failure' } });
    assert.equal((await complete(env)).code, String(code));
    assert.equal(env.queries.length, 0);
  });
}
test('synchronous SDK failure also settles the call', async () => {
  const env = setup({ syncError: { code: 401, message: 'bad arguments' } });
  assert.equal((await complete(env)).code, '401');
});
test('legacy credentials get type from cache and still avoid querying', async () => {
  const env = setup();
  assert.equal((await complete(env, credential({ productType: undefined }))).ok, true);
  assert.equal(env.queries.length, 0);
});
for (const extra of [{ purchaseOrderId: 'other' }, { productId: 'other' }]) {
  test(`rejects credential mismatch ${Object.keys(extra)[0]}`, async () => {
    const env = setup();
    assert.equal((await complete(env, credential(extra))).code, 'INVALID_PURCHASE');
    assert.equal(env.finishes.length, 0);
    assert.equal(env.queries.length, 0);
  });
}
test('missing transaction ID never completes arbitrary orders', async () => {
  const env = setup();
  assert.equal((await complete(env, credential(), { transactionIdentifier: '' })).code, 'INVALID_PURCHASE');
  assert.equal(env.finishes.length, 0);
});
test('legacy lookup matches product AND order across pages; replies only once', async () => {
  const env = setup({ pages: [
    { purchaseDataList: [purchase({ orderId: 'unverified-order' }), purchase({ productId: 'different-product' })], continuationToken: 'p2' },
    { purchaseDataList: [purchase({ tokenInOrder: true }), purchase({ orderId: 'another-unverified-order' })] },
  ] });
  assert.equal((await complete(env, null)).ok, true);
  assert.equal(env.queries.length, 2);
  assert.equal(env.queries[1].continuationToken, 'p2');
  assert.equal(env.finishes.length, 1);
  assert.equal(env.finishes[0].purchaseOrderId, ORDER);
});
test('empty unfinished list is unknown, not evidence of delivery', async () => {
  const env = setup();
  assert.equal((await complete(env, null)).code, 'PURCHASE_NOT_FOUND');
  assert.equal(env.finishes.length, 0);
});
test('empty page with continuation still queries the next page', async () => {
  const env = setup({ pages: [
    { purchaseDataList: [], continuationToken: 'p2' }, { purchaseDataList: [purchase()] },
  ] });
  assert.equal((await complete(env, null)).ok, true);
});
test('malformed and unrelated orders are never finished', async () => {
  const env = setup({ pages: [{ purchaseDataList: ['invalid json', purchase({ orderId: 'other' })] }] });
  assert.equal((await complete(env, 'legacy-receipt')).code, 'PURCHASE_NOT_FOUND');
  assert.equal(env.finishes.length, 0);
});
test('cyclic pagination fails instead of looping forever', async () => {
  const env = setup({ pages: ['p2', 'p3', 'p2'].map(continuationToken => ({ purchaseDataList: [], continuationToken })) });
  assert.equal((await complete(env, null)).code, 'UNAVAILABLE');
  assert.equal(env.queries.length, 3);
});
test('query errors propagate without finishing any order', async () => {
  const error = Object.assign(new Error('network failed'), { code: 1001860005 });
  const env = setup({ pages: [error] });
  assert.equal((await complete(env, null)).code, '1001860005');
  assert.equal(env.finishes.length, 0);
});
test('missing product cache is handled without dereferencing undefined', async () => {
  const env = setup({ cache: false });
  assert.equal((await complete(env, null)).code, 'UNAVAILABLE');
});
for (const type of [0, 1]) {
  test(`legacy non-subscription type ${type} matches only the requested order`, async () => {
    const env = setup({ pages: [{ purchaseDataList: [purchase({ type, orderId: 'other' }), purchase({ type })] }] });
    env.handler.productDetailsMap.set(PRODUCT, { type });
    assert.equal((await complete(env, null)).ok, true);
    assert.equal(env.finishes.length, 1);
    assert.equal(env.finishes[0].productType, type);
  });
}
for (const type of [0, TYPE]) {
  test(`purchase callback type ${type} carries store timestamp in seconds`, async () => {
    const env = setup();
    env.handler.productDetailsMap.set(PRODUCT, { type });
    const purchaseTime = 1792497234295;
    const order = { purchaseOrderId: ORDER, purchaseToken: TOKEN, purchaseTime };
    const data = type === TYPE ? {
      type, jwsSubscriptionStatus: JSON.stringify({ lastSubscriptionStatus: { lastPurchaseOrder: order } }),
    } : { type, jwsPurchaseOrder: JSON.stringify(order) };
    env.iap.createPurchase = async () => ({ purchaseData: JSON.stringify(data) });
    env.handler.startObserver();
    await new Promise((resolve, reject) => env.handler.createPurchase(PRODUCT, new Map(), { success: resolve, error: reject }));
    const callback = env.updates[0][0];
    assert.equal(callback.get('transactionTimeStamp'), purchaseTime / 1000);
    assert.equal(JSON.parse(callback.get('verificationData')).productId, PRODUCT);
  });
}

test('detached ability leaves the purchase unfinished and replies with an error', async () => {
  const env = setup();
  env.handler.setContext(null);
  assert.equal((await complete(env)).code, 'UNAVAILABLE');
  assert.equal(env.finishes.length, 0);
});

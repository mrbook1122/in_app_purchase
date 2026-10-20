# in\_app\_purchase\_ohos

The Ohos implementation of [`in_app_purchase`][1].

## Usage

This package is [endorsed][2], which means you can simply use `in_app_purchase`
normally. This package will be automatically included in your app when you do,
so you do not need to add it to your `pubspec.yaml`.

## Contributing

This plugin utilizes
[json_serializable](https://pub.dev/packages/json_serializable) for the
numerous data structures communicated between the underlying platform layers and Dart. After
modifying any of the serialized data structures, regenerate the serializers by executing
`flutter pub run build_runner build --delete-conflicting-outputs`.
`flutter pub run build_runner watch --delete-conflicting-outputs` will supervise the filesystem for changes.

If you are interested in contributing to the plugin, please consult our
[contribution guidelines](https://github.com/flutter/plugins/blob/main/CONTRIBUTING.md).

[1]: https://pub.dev/packages/in_app_purchase
[2]: https://flutter.dev/docs/development/packages-and-plugins/developing-packages#endorsed-federated-plugin

### Completing HarmonyOS purchases

Call `completePurchase` only after verifying the order and delivering its entitlement.
The plugin uses the callback's order ID, purchase token and product type to finish
that exact purchase. Huawei's `PURCHASE_FINISHED` (1001860053) is treated as success,
including when a server has already confirmed delivery. Other SDK errors propagate.
After success, `pendingCompletePurchase` becomes `false` on that purchase object.

For older callbacks without credentials, query product details first so the plugin
can determine the product type. The fallback searches all `UNFINISHED` pages and
matches both product ID and order ID. An absent order returns `PURCHASE_NOT_FOUND`:
an empty list alone does not prove delivery, so reconcile with the server instead
of marking arbitrary orders complete. Network and unknown-delivery failures leave
`pendingCompletePurchase` unchanged for retry/reconciliation.

Transaction dates use the store's purchase time when provided; a missing time
remains `null` rather than being replaced with the current time.

Regression tests:

```sh
flutter test test/complete_purchase_test.dart
# IAP_TYPESCRIPT can point to the TypeScript module in your HarmonyOS SDK.
IAP_TYPESCRIPT=/path/to/typescript node --test tool/finish_purchase_test.cjs
```

The Node tests run the actual handler with mocked SDK responses. They do not replace
ArkTS compilation or sandbox tests on a HarmonyOS device.

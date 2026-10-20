import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase_ohos/iap_kit_wrappers.dart';
import 'package:in_app_purchase_ohos/in_app_purchase_ohos.dart';
import 'package:in_app_purchase_ohos/src/channel.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  PlatformException? failure;

  AppGalleryPurchaseDetails purchase() =>
      AppGalleryPurchaseDetails.fromIKTransaction(
        IKPaymentTransactionWrapper(
          payment: const IKPaymentWrapper(productId: 'subscription.monthly'),
          transactionState: IKPaymentTransactionStateWrapper.purchased,
          transactionIdentifier: 'order-123',
          transactionTimeStamp: 1792497234.295,
          verificationData:
              '{"purchaseOrderId":"order-123","purchaseToken":"test-token","productType":2}',
        ),
        '',
      );

  setUp(() {
    calls = <MethodCall>[];
    failure = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (failure != null) throw failure!;
      return null;
    });
    InAppPurchaseOhosPlatform.registerPlatform();
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
      'completes exact credentials and clears pending only after acknowledgement',
      () async {
    final details = purchase();
    expect(details.pendingCompletePurchase, isTrue);
    await InAppPurchasePlatform.instance.completePurchase(details);
    expect(details.pendingCompletePurchase, isFalse);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'iap#finishPurchase');
    expect(calls.single.arguments['transactionIdentifier'], 'order-123');
    expect(calls.single.arguments['productIdentifier'], 'subscription.monthly');
    expect(calls.single.arguments['verificationData'],
        details.verificationData.serverVerificationData);
  });

  for (final code in <String>['1001860005', 'PURCHASE_NOT_FOUND']) {
    test('$code preserves pending for a later retry', () async {
      final details = purchase();
      failure = PlatformException(code: code, message: 'retry or reconcile');
      await expectLater(
          InAppPurchasePlatform.instance.completePurchase(details),
          throwsA(isA<PlatformException>()
              .having((error) => error.code, 'code', code)));
      expect(details.pendingCompletePurchase, isTrue);
      failure = null;
      await InAppPurchasePlatform.instance.completePurchase(details);
      expect(details.pendingCompletePurchase, isFalse);
    });
  }

  test(
      'store time becomes millisecond transactionDate without synthesizing now',
      () {
    expect(purchase().transactionDate, '1792497234295');
    final missingTime = AppGalleryPurchaseDetails.fromIKTransaction(
      IKPaymentTransactionWrapper(
        payment: const IKPaymentWrapper(productId: 'subscription.monthly'),
        transactionState: IKPaymentTransactionStateWrapper.purchased,
        transactionIdentifier: 'order-without-time',
      ),
      '',
    );
    expect(missingTime.transactionDate, isNull);
  });
}

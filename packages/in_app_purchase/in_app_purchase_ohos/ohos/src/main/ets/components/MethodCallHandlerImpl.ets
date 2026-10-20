/*
* Copyright (c) 2024 SwanLink (Jiangsu) Technology Development Co., LTD.
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

import { MethodCall, MethodCallHandler, MethodChannel, MethodResult, Log, Any } from '@ohos/flutter_ohos';
import { MethodNames } from './MethodNames';
import { iap } from '@kit.IAPKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { ProductType } from './ProductType';
import { JWTUtil } from '../common/JWTUtil';
import { PurchaseOrderPayload, PurchaseSubGroupStatusPayload } from './PurchaseOrderPayload';
import { HashMap } from '@kit.ArkTS';
import { TransactionState } from './TransactionState';
import { PurchaseData } from './PurchaseData';
import { ObjToMap } from '../common/TsUtil';

const TAG = "MethodCallHandlerImpl"

export class IKError {
  code: number = 0
  domain: string = ''
  userInfo: Map<String, Any> = new Map()
}

interface FinishPurchaseCredential {
  purchaseOrderId?: string;
  purchaseToken?: string;
  productType?: number;
  productId?: string;
}

export class MethodCallHandlerImpl implements MethodCallHandler {
  private context: common.UIAbilityContext | null = null
  private methodChannel: MethodChannel
  private observer: MethodChannel | null = null
  private productDetailsMap: HashMap<string, iap.Product> = new HashMap()

  constructor(context: common.Context, methodChannel: MethodChannel) {
    this.methodChannel = methodChannel
  }

  setContext(context: common.UIAbilityContext | null) {
    this.context = context
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case MethodNames.START_OBSERVING_TRANSACTION_QUEUE:
        this.startObserver()
        break;
      case MethodNames.STOP_OBSERVING_TRANSACTION_QUEUE:
        this.stopObserver()
        break;
      case MethodNames.QUERY_ENVIRONMENT_STATUS:
        this.isFeatureSupported(result)
        break;
      case MethodNames.QUERY_PRODUCTS:
        let productList: Array<string> = call.args as Array<string> ?? []
        this.queryProductDetails(productList, result)
        break;
      case MethodNames.CREATE_PURCHASE:
        this.purchaseGoods(call.args, result)
        break;
      case MethodNames.RETRIEVE_RECEIPT_DATA:
        result.success(null)
        break;
      case MethodNames.FINISH_PURCHASE:
        this.iapFinishPurchase(call, result)
        break;
      default:
        result.notImplemented();
    }
  }

  isFeatureSupported(result: MethodResult): void {
    try {
      iap.queryEnvironmentStatus(this.context).then(() => {
        result.success(true);
      }).catch((err: BusinessError) => {
        Log.e(TAG, `Failed to query environment status. Code is ${err.code}, message is ${err.message}`);
        result.success(false);
      })
    } catch (e) {
      Log.e(TAG, `Failed to query environment status. err: ${JSON.stringify(e)}`);
      result.success(false);
    }
  }

  queryProductDetails(list: Array<string>, result: MethodResult) {
    let productList: Array<Map<string, Object>> = []
    let count: number = 0
    let validProductsList: Array<string> = []
    let invalidProductIdentifiers: Array<string> = []
    ProductType.forEach((type) => {
      const queryProductParam: iap.QueryProductsParameter = {
        productType: type,
        productIds: list
      };
      iap.queryProducts(this.context, queryProductParam).then((result) => {
        let resultTemp = result.map((value) => {
          validProductsList.push(value.id)
          this.productDetailsMap.set(value.id, value)
          return ObjToMap(value)
        })
        productList.push(...resultTemp)
      }).catch((err: BusinessError) => {
        Log.e(TAG, `Failed to query products. Code is ${err.code}, message is ${err.message}`);
      }).finally(() => {
        count++
        if (count === ProductType.length) {
          let productDetailsResponse: HashMap<String, Object> = new HashMap()
          productDetailsResponse.set('products', productList)
          list.forEach((id) => {
            if (!validProductsList.includes(id)) {
              invalidProductIdentifiers.push(id)
            }
          })
          productDetailsResponse.set('invalidProductIdentifiers', invalidProductIdentifiers)
          result.success(productDetailsResponse)
        }
      })
    })
  }

  purchaseGoods(args: Any, result: MethodResult) {
    let map: Map<string, Object> = args as Map<string, Object>
    let id: string = map.get('productId') as string
    // 拉起支付接口前更新状态为支付中
    let mapRes: Map<string, Any> = new Map()
    mapRes.set('payment', args)
    mapRes.set('transactionState', TransactionState.purchasing)
    this.observer?.invokeMethod('updatedTransactions', [mapRes])
    this.createPurchase(id, map, result)
  }

  createPurchase(id: string, args: Map<string, Object>, result: MethodResult) {
    try {
      const type = this.productDetailsMap.get(id).type
      let createPurchaseParam: iap.PurchaseParameter = {
        productId: id,
        productType: type,
      }
      iap.createPurchase(this.context, createPurchaseParam).then(async (createPurchaseResult) => {
        let type: number = JSON.parse(createPurchaseResult.purchaseData).type
        if (type == iap.ProductType.AUTORENEWABLE) {
          let jwsSubscriptionStatus: string = JSON.parse(createPurchaseResult.purchaseData).jwsSubscriptionStatus;
          let purchaseStr = JWTUtil.decodeJwtObj(jwsSubscriptionStatus);
          let purchaseOrderPayload = JSON.parse(purchaseStr) as PurchaseSubGroupStatusPayload;
          let subscriptionStatus = purchaseOrderPayload.lastSubscriptionStatus;
          let purchaseOrderId: string = subscriptionStatus?.lastPurchaseOrder?.purchaseOrderId ?? '';
          let purchaseToken: string =
            subscriptionStatus?.purchaseToken ?? subscriptionStatus?.lastPurchaseOrder?.purchaseToken ?? '';
          let map: Map<string, Any> = new Map();
          map.set('payment', args)
          map.set('transactionIdentifier', purchaseOrderId)
          this.setPurchaseTime(map, subscriptionStatus?.lastPurchaseOrder?.purchaseTime)
          map.set('verificationData', this.buildVerificationData(purchaseOrderId, purchaseToken, type, id))
          map.set('transactionState', TransactionState.purchased)
          this.observer?.invokeMethod('updatedTransactions', [map])
        } else if (type == iap.ProductType.CONSUMABLE || type == iap.ProductType.NONCONSUMABLE) {
          let jwsPurchaseOrder: string = JSON.parse(createPurchaseResult.purchaseData).jwsPurchaseOrder;
          let purchaseStr = JWTUtil.decodeJwtObj(jwsPurchaseOrder);
          let purchaseOrderPayload = JSON.parse(purchaseStr) as PurchaseOrderPayload;
          let purchaseOrderId: string = purchaseOrderPayload.purchaseOrderId;
          let purchaseToken: string = purchaseOrderPayload.purchaseToken;
          let map: Map<string, Any> = new Map();
          map.set('payment', args)
          map.set('transactionIdentifier', purchaseOrderId)
          this.setPurchaseTime(map, purchaseOrderPayload.purchaseTime)
          map.set('verificationData', this.buildVerificationData(purchaseOrderId, purchaseToken, type, id))
          map.set('transactionState', TransactionState.purchased)
          this.observer?.invokeMethod('updatedTransactions', [map])
        }
        result.success(null)
      }).catch((err: BusinessError) => {
        Log.e(TAG, `Failed to create purchase1. Code is ${err.code}, message is ${err.message}`);
        this.errorPurchase(args, err);
      })
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      const msg: string = `Failed to create purchase. Code is ${e.code}, message is ${e.message}`;
      Log.e(TAG, msg);
      this.errorPurchase(args, err);
    }
  }

  errorPurchase(args: Map<string, Object>, err: BusinessError) {
    let map: Map<string, Any> = new Map();
    let iKError: IKError = new IKError()
    if (err) {
      iKError.code = err.code
      iKError.domain = err.message
    }
    map.set('error', iKError)
    map.set('payment', args)
    map.set('transactionState', TransactionState.failed)
    this.observer?.invokeMethod('updatedTransactions', [map])
  }

  // 组装服务端验单所需的华为订单凭据，Flutter 侧会原样透传给后端。
  buildVerificationData(
    purchaseOrderId: string | undefined,
    purchaseToken: string | undefined,
    productType: number | undefined,
    productId?: string
  ): string {
    return JSON.stringify({
      purchaseOrderId: purchaseOrderId ?? '',
      purchaseToken: purchaseToken ?? '',
      productType: productType,
      productId: productId
    })
  }

  // PurchaseOrder.purchaseTime is milliseconds; the Dart wrapper expects seconds.
  private setPurchaseTime(transaction: Map<string, Any>, purchaseTime: number | undefined): void {
    if (typeof purchaseTime === 'number' && Number.isFinite(purchaseTime) && purchaseTime > 0) {
      transaction.set('transactionTimeStamp', purchaseTime / 1000);
    }
  }

  private async finishPurchase(credential: FinishPurchaseCredential): Promise<void> {
    if (this.context === null) {
      throw new Error('IAP ability context is unavailable.');
    }
    const parameter: iap.FinishPurchaseParameter = {
      productType: credential.productType as iap.ProductType,
      purchaseToken: credential.purchaseToken as string,
      purchaseOrderId: credential.purchaseOrderId as string
    };
    try {
      await iap.finishPurchase(this.context as common.UIAbilityContext, parameter);
    } catch (err) {
      const error = err as BusinessError;
      // Only this documented response proves the exact order is already delivered.
      // Do not treat an empty query, network error or unpaid order as success.
      if (error.code !== iap.IAPErrorCode.PURCHASE_FINISHED) {
        throw error as Error;
      }
      Log.i(TAG, 'Purchase already finished.');
    }
  }

  private parseFinishCredential(data: string | undefined): FinishPurchaseCredential | undefined {
    if (!data) {
      return undefined;
    }
    try {
      return JSON.parse(data) as FinishPurchaseCredential;
    } catch (_) {
      // Older callbacks may carry a receipt instead of credential JSON.
      return undefined;
    }
  }

  private isNonEmptyString(value: string | undefined): boolean {
    return typeof value === 'string' && value.trim().length > 0;
  }

  // Legacy callbacks can lack a token. Query every page, but only finish the
  // exact order that the caller has verified; never finish other pending orders.
  private async findUnfinishedPurchase(
    productType: iap.ProductType,
    productId: string,
    purchaseOrderId: string
  ): Promise<FinishPurchaseCredential | undefined> {
    if (this.context === null) {
      throw new Error('IAP ability context is unavailable.');
    }
    let continuationToken: string | undefined = undefined;
    const seenTokens = new Set<string>();
    while (true) {
      const parameter: iap.QueryPurchasesParameter = {
        productType: productType,
        queryType: iap.PurchaseQueryType.UNFINISHED
      };
      if (continuationToken) {
        parameter.continuationToken = continuationToken;
      }
      const response: iap.QueryPurchaseResult = await iap.queryPurchases(this.context as common.UIAbilityContext, parameter);
      for (const rawPurchase of response.purchaseDataList ?? []) {
        const credential = this.matchPurchase(rawPurchase, productType, productId, purchaseOrderId);
        if (credential) {
          return credential;
        }
      }
      const nextToken = response.continuationToken;
      if (!nextToken) {
        return undefined;
      }
      if (seenTokens.has(nextToken)) {
        throw new Error('Repeated purchase continuation token.');
      }
      seenTokens.add(nextToken);
      continuationToken = nextToken;
    }
  }

  private matchPurchase(
    rawPurchase: string,
    productType: iap.ProductType,
    productId: string,
    purchaseOrderId: string
  ): FinishPurchaseCredential | undefined {
    try {
      const data = JSON.parse(rawPurchase) as PurchaseData;
      if (data.type !== productType) {
        return undefined;
      }
      let order: PurchaseOrderPayload | undefined;
      let purchaseToken: string | undefined;
      if (productType === iap.ProductType.AUTORENEWABLE && data.jwsSubscriptionStatus) {
        const payload = JSON.parse(JWTUtil.decodeJwtObj(data.jwsSubscriptionStatus)) as PurchaseSubGroupStatusPayload;
        order = payload.lastSubscriptionStatus?.lastPurchaseOrder as PurchaseOrderPayload | undefined;
        purchaseToken = payload.lastSubscriptionStatus?.purchaseToken || order?.purchaseToken;
      } else if (data.jwsPurchaseOrder) {
        order = JSON.parse(JWTUtil.decodeJwtObj(data.jwsPurchaseOrder)) as PurchaseOrderPayload;
        purchaseToken = order.purchaseToken;
      }
      if (order?.purchaseOrderId !== purchaseOrderId || order?.productId !== productId ||
        !this.isNonEmptyString(purchaseToken)) {
        return undefined;
      }
      return { purchaseOrderId: purchaseOrderId, purchaseToken: purchaseToken, productType: productType,
        productId: productId };
    } catch (_) {
      Log.e(TAG, 'Ignoring malformed purchase data while locating the requested order.');
      return undefined;
    }
  }

  async iapFinishPurchase(call: MethodCall, result: MethodResult): Promise<void> {
    // Respond to the MethodChannel exactly once, including synchronous SDK errors.
    try {
      const args = call.args as Map<string, Object>;
      const productId = args.get('productIdentifier') as string;
      const purchaseOrderId = args.get('transactionIdentifier') as string;
      if (!this.isNonEmptyString(productId) || !this.isNonEmptyString(purchaseOrderId)) {
        result.error('INVALID_PURCHASE', 'Product ID and transaction ID are required.', null);
        return;
      }
      let credential = this.parseFinishCredential(args.get('verificationData') as string | undefined);
      if (credential &&
        ((this.isNonEmptyString(credential.purchaseOrderId) && credential.purchaseOrderId !== purchaseOrderId) ||
        (this.isNonEmptyString(credential.productId) && credential.productId !== productId))) {
        result.error('INVALID_PURCHASE', 'Credential does not match the requested transaction.', null);
        return;
      }
      const product = this.productDetailsMap.get(productId);
      const productType = this.isSupportedProductType(credential?.productType) ?
        credential?.productType : product?.type;
      if (!this.isSupportedProductType(productType)) {
        result.error('UNAVAILABLE', 'Product type unavailable; query product details before retrying.', null);
        return;
      }
      if (credential?.purchaseOrderId === purchaseOrderId && this.isNonEmptyString(credential?.purchaseToken)) {
        credential.productType = productType;
      } else {
        credential = await this.findUnfinishedPurchase(productType as iap.ProductType, productId, purchaseOrderId);
      }
      if (!credential) {
        // Absence from UNFINISHED does not prove delivery. Keep the transaction
        // pending so the app can reconcile with its server instead of losing it.
        result.error('PURCHASE_NOT_FOUND', 'Requested order not found in unfinished purchases; delivery status is unknown.', null);
        return;
      }
      await this.finishPurchase(credential);
      result.success(null);
    } catch (err) {
      const error = err as BusinessError;
      result.error(error.code === undefined ? 'UNAVAILABLE' : String(error.code),
        error.message ?? 'Failed to finish purchase.', null);
    }
  }

  isSupportedProductType(productType: number | undefined): boolean {
    return productType == iap.ProductType.CONSUMABLE ||
      productType == iap.ProductType.NONCONSUMABLE ||
      productType == iap.ProductType.AUTORENEWABLE
  }

  startObserver() {
    this.observer = this.methodChannel
  }

  stopObserver() {
    this.observer = null
  }
}

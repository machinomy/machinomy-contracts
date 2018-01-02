import * as BigNumber from 'bignumber.js'
import Broker from '../../build/wrappers/Broker'
import Address from './Address'
import PaymentChannel from './PaymentChannel'
import * as truffle from 'truffle-contract'

export const FAKE_CHANNEL_ID = '0xdeadbeaf'

export interface Opts {
  instance: Broker.Contract
  channelValue: BigNumber.BigNumber
  sender: Address
  receiver: Address
  alien: Address
}

export interface OpenChannelOpts {
  sender?: Address
  receiver?: Address
  settlingPeriod?: number
}

export class BrokerScaffold {
  instance: Broker.Contract
  channelValue: BigNumber.BigNumber
  sender: Address
  receiver: Address
  alien: Address

  constructor (opts: Opts) {
    this.instance = opts.instance
    this.channelValue = opts.channelValue
    this.sender = opts.sender
    this.receiver = opts.receiver
    this.alien = opts.alien
  }

  async openChannel (opts: OpenChannelOpts = {}): Promise<string> {
    let options = {
      value: this.channelValue,
      from: opts.sender || this.sender
    }
    let receiver = opts.receiver || this.receiver
    let settlementPeriod = opts.settlingPeriod || 0
    let log = await this.instance.open(receiver, settlementPeriod, options)
    let logEvent = log.logs[0]
    if (Broker.isDidOpenEvent(logEvent)) {
      return logEvent.args.channelId
    } else {
      return Promise.reject(log.receipt)
    }
  }

  async readChannel (channelId: string): Promise<PaymentChannel> {
    let raw = await this.instance.channels(channelId)
    let [ sender, receiver, value, root, settlingPeriod, settlingUntil, nonce ] = raw
    return { sender, receiver, value, root, settlingPeriod, settlingUntil, nonce }
  }

  async startSettling (channelId: string, _origin?: string): Promise<truffle.TransactionResult> {
    let origin = _origin || this.sender
    return this.instance.startSettling(channelId, {from: origin})
  }
}
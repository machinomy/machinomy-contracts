import * as Web3 from 'web3'
import BigNumber from 'bignumber.js'

import * as chai from 'chai'
import * as asPromised from 'chai-as-promised'
import * as abi from 'ethereumjs-abi'
import * as util from 'ethereumjs-util'

import { ABroker } from '../src/index'
import { getNetwork } from './support'

chai.use(asPromised)

const assert = chai.assert

const web3 = (global as any).web3 as Web3

enum PaymentChannelState {
  OPEN = 0
}

interface PaymentChannel {
  sender: string
  receiver: string
  value: BigNumber
  state: BigNumber
}

contract('ABroker', accounts => {
  let sender = accounts[0]
  let receiver = accounts[1]
  let delta = new BigNumber(web3.toWei(0.1, 'ether'))

  async function deployed (): Promise<ABroker.Contract> {
    let contract = artifacts.require<ABroker.Contract>('ABroker.sol')
    if (contract.isDeployed()) {
      return contract.deployed()
    } else {
      let networkId = await getNetwork(web3)
      return contract.new(networkId, {from: sender, gas: 1800000})
    }
  }

  async function createChannel (instance: ABroker.Contract): Promise<string> {
    let options = { value: delta, from: sender }
    let log = await instance.openChannel(receiver, options)
    let logEvent = log.logs[0]
    if (ABroker.isDidCreateChannelEvent(logEvent)) {
      return logEvent.args.channelId
    } else {
      return Promise.reject(log.receipt)
    }
  }

  async function readChannel (instance: ABroker.Contract, channelId: string): Promise<PaymentChannel> {
    let [sender, receiver, value, state] = await instance.channels(channelId)
    return { sender, receiver, value, state }
  }

  async function paymentDigest (address: string, channelId: string, payment: BigNumber): Promise<string> {
    let chainId = await getNetwork(web3)
    let hash = abi.soliditySHA3(
      ['address', 'uint32', 'bytes32', 'uint256'],
      [address, chainId, channelId, payment.toString()]
    )
    return util.bufferToHex(hash)
  }

  async function signatureDigest (address: string, channelId: string, payment: BigNumber): Promise<string> {
    let digest = await paymentDigest(address, channelId, payment)
    let prefix = Buffer.from("\x19Ethereum Signed Message:\n32")
    let hash = abi.soliditySHA3(
      ['bytes', 'bytes32'],
      [prefix, digest]
    )
    return util.bufferToHex(hash)
  }

  describe('createChannel', () => {
    specify('emit DidCreateChannel event', async () => {
      let instance = await deployed()
      let channelId = await createChannel(instance)
      assert.typeOf(channelId, 'string')
    })

    specify('increase contract balance', async () => {
      let instance = await deployed()
      let startBalance = web3.eth.getBalance(instance.address)
      await createChannel(instance)
      let endBalance = web3.eth.getBalance(instance.address)
      assert.deepEqual(endBalance, startBalance.plus(delta))
    })

    specify('set channel parameters', async () => {
      let instance = await deployed()
      let channelId = await createChannel(instance)
      let channel = await readChannel(instance, channelId)
      assert.equal(channel.sender, sender)
      assert.equal(channel.receiver, receiver)
      assert(channel.value.eq(delta))
      assert(channel.state.eq(PaymentChannelState.OPEN))
    })
  })

  describe('paymentDigest', () => {
    specify('returns hash of the payment', async () => {
      let instance = await deployed()
      let channelId = '0xdeadbeaf'
      let payment = new BigNumber(10)
      let digest = await instance.paymentDigest(channelId, payment)
      let expected = await paymentDigest(instance.address, channelId, payment)
      assert.equal(digest, expected)
    })
  })

  describe('signatureDigest', () => {
    specify('returns prefixed hash to be signed', async () => {
      let instance = await deployed()
      let channelId = '0xdeadbeaf'
      let payment = new BigNumber(10)
      let digest = await instance.signatureDigest(channelId, payment)
      let expected = await signatureDigest(instance.address, channelId, payment)
      assert.equal(digest, expected)
    })
  })
})

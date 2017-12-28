pragma solidity ^0.4.18;

import "zeppelin-solidity/contracts/lifecycle/Destructible.sol";
import "zeppelin-solidity/contracts/math/SafeMath.sol";
import "zeppelin-solidity/contracts/ECRecovery.sol";


contract BBroker is Destructible {
    using SafeMath for uint256;

    struct PaymentChannel {
        address sender;
        address receiver;
        uint256 value;

        bytes32 merkleRoot;

        uint32 settlingPeriod;
        uint256 settlingUntil;

        uint32 nonce;
    }

    mapping (bytes32 => PaymentChannel) public channels;

    uint32 public chainId;
    uint256 id;

    event DidOpen(bytes32 indexed channelId);
    event DidUpdate(bytes32 indexed channelId, bytes32 merkleRoot);
    event DidStartSettling(bytes32 indexed channelId, address indexed sender, address indexed receiver);
    event DidWithdraw(bytes32 indexed channelId, address destination, int256 amount);
    event DidClose(bytes32 indexed channelId);

    function BBroker(uint32 _chainId) public {
        chainId = _chainId;
        id = 0;
    }

    function open(address receiver, uint32 settlingPeriod) public payable {
        bytes32 channelId = keccak256(block.number + id++);
        bytes32 merkleRoot = 0;
        uint256 settlingUntil = 0;
        uint32 nonce;
        channels[channelId] = PaymentChannel(
            msg.sender,
            receiver,
            msg.value,
            merkleRoot,
            settlingPeriod,
            settlingUntil,
            nonce
        );
        DidOpen(channelId);
    }

    function canStartSettling(bytes32 channelId, address origin) public view returns(bool) {
        var channel = channels[channelId];
        bool isParty = (channel.sender == origin) || (channel.receiver == origin);
        return isOpen(channelId) && isParty;
    }

    function startSettling(bytes32 channelId) public {
        require(canStartSettling(channelId, msg.sender));

        var channel = channels[channelId];
        channel.settlingUntil = block.number + channel.settlingPeriod;

        DidStartSettling(channelId, channel.sender, channel.receiver);
    }

    function updateFingerprint(bytes32 channelId, uint32 nonce, bytes32 merkleRoot) public view returns(bytes32) {
        return keccak256("u", address(this), channelId, nonce, merkleRoot);
    }

    function canUpdate(bytes32 channelId, uint32 nonce, bytes32 merkleRoot, bytes senderSig, bytes receiverSig) public view returns(bool) {
        var channel = channels[channelId];
        var digest = signatureDigest(updateFingerprint(channelId, nonce, merkleRoot));
        bool isSignedBySender = channel.sender == ECRecovery.recover(digest, senderSig);
        bool isSignedByReceiver = channel.receiver == ECRecovery.recover(digest, receiverSig);
        bool isHigherNonce = nonce > channel.nonce;
        return !isSettled(channelId) && isHigherNonce && isSignedBySender && isSignedByReceiver;
    }

    function update(bytes32 channelId, uint32 nonce, bytes32 merkleRoot, bytes senderSig, bytes receiverSig) public {
        require(canUpdate(channelId, nonce, merkleRoot, senderSig, receiverSig));

        var channel = channels[channelId];
        channel.merkleRoot = merkleRoot;
        channel.nonce = nonce;

        DidUpdate(channelId, merkleRoot);
    }

    function canWithdraw(bytes32 channelId, bytes proof, bytes32 preimage, int256 amount) public view returns(bool) {
        var channel = channels[channelId];
        var hashlock = toHashlock(channelId, preimage, amount);
        var isProof = checkProof(proof, channel.merkleRoot, hashlock);
        return isSettled(channelId) && isProof;
    }

    function withdraw(bytes32 channelId, bytes proof, bytes32 preimage, int256 amount) public {
        require(canWithdraw(channelId, proof, preimage, amount));

        var channel = channels[channelId];

        if (amount >= 0) {
            var payment = uint256(amount);
            channel.value -= payment;
            require(channel.receiver.send(payment));
            DidWithdraw(channelId, channel.receiver, amount);
        }

        if (channel.value == 0) {
            delete channels[channelId];
            DidClose(channelId);
        }
    }

    /** Digest **/
    function isSignedPayment(bytes32 channelId, bytes32 merkleRoot, bytes senderSig, bytes receiverSig) public view returns(bool) {
        var channel = channels[channelId];
        var digest = signatureDigest(paymentDigest(channelId, merkleRoot));
        bool isSignedBySender = channel.sender == ECRecovery.recover(digest, senderSig);
        bool isSignedByReceiver = channel.receiver == ECRecovery.recover(digest, receiverSig);
        return isSignedBySender && isSignedByReceiver;
    }

    function paymentDigest(bytes32 channelId, bytes32 merkleRoot) public view returns(bytes32) {
        return keccak256(address(this), chainId, channelId, merkleRoot);
    }

    function signatureDigest(bytes32 digest) public pure returns(bytes32) {
        bytes memory prefix = "\x19Ethereum Signed Message:\n32";
        return keccak256(prefix, digest);
    }

    /** Hashlocks and Merkle Trees **/

    function toHashlock(bytes32 channelId, bytes32 preimage, int256 amount) public view returns (bytes32) {
        return keccak256(chainId, channelId, preimage, amount);
    }

    function checkProof(bytes proof, bytes32 merkleRoot, bytes32 hashlock) public pure returns (bool) {
        bytes32 proofElement;
        bytes32 cursor = hashlock;

        for (uint256 i = 32; i <= proof.length; i += 32) {
            assembly { proofElement := mload(add(proof, i)) }

            if (cursor < proofElement) {
                cursor = keccak256(cursor, proofElement);
            } else {
                cursor = keccak256(proofElement, cursor);
            }
        }

        return cursor == merkleRoot;
    }

    /** Channel State **/
    function isPresent(bytes32 channelId) public view returns(bool) {
        var channel = channels[channelId];
        return channel.sender != 0;
    }

    function isOpen(bytes32 channelId) public view returns(bool) {
        var channel = channels[channelId];
        return channel.sender != 0 && channel.settlingUntil == 0;
    }

    function isSettling(bytes32 channelId) public view returns(bool) {
        var channel = channels[channelId];
        return block.number < channel.settlingUntil;
    }

    function isSettled(bytes32 channelId) public view returns(bool) {
        var channel = channels[channelId];
        return 0 < channel.settlingUntil && channel.settlingUntil <= block.number;
    }
}

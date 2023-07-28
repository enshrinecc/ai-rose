// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import {TaskIdSelectorOps} from "@escrin/evm/contracts/tasks/acceptor/TaskAcceptor.sol";
import {DelegatedTaskAcceptorV1} from "@escrin/evm/contracts/tasks/acceptor/DelegatedTaskAcceptor.sol";
import {SimpleTimelockedTaskAcceptorV1Proxy} from "@escrin/evm/contracts/tasks/widgets/TaskAcceptorProxy.sol";
import {TaskHubV1Notifier} from "@escrin/evm/contracts/tasks/widgets/TaskHubNotifier.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

contract Bridge is
    IERC721Receiver,
    DelegatedTaskAcceptorV1,
    SimpleTimelockedTaskAcceptorV1Proxy,
    TaskHubV1Notifier,
    Ownable
{
    using TaskIdSelectorOps for TaskIdSelector;

    /// The token sent to the bridge contract is not supported or not approved.
    error UnsupportedToken(); // 6a172882 ahcogg==
    /// This operation cannot be performed yet.
    error TooSoon(); // 6fed7d85 b+19hQ==
    /// The token cannot be reclaimed because it has already been bridged.
    error AlreadyBridged(); // 4cd4ddb79 TNTdtw==

    struct SupportedToken {
        /// The token will become active once a majority of tokens have approved.
        uint256 approvals;
        uint256 quorum;
        mapping(uint256 /* token id */ => bool) voted;
    }

    /// Uniquely identifies a particular NFT bound to its original holder.
    struct TokenDescriptor {
        address token;
        uint256 id;
        address holder;
    }

    struct TokenState {
        bool bridged;
        uint64 unlockTimestamp; // Nonzero only when `bridged` is `false`
    }

    event TokenProposed(address indexed token);
    event TokenApproved(address indexed token);
    event BridgingRequested(TokenDescriptor desc);
    event TokenReclaimed(TokenDescriptor indexed desc, address operator);

    /// The time in seconds during which bridging must occur before a sent token may be reclaimed. This aims to prevent any bugs in the bridge from making tokens inaccessible.
    uint256 public immutable bridgingTimeout;

    mapping(address => SupportedToken) public supportedTokens;
    mapping(uint256 /* task id */ => TokenState) public knownTokens;

    constructor(
        uint256 _bridgingTimeout,
        uint256 _taskAcceptorUpdateDelay,
        address _initialTaskAcceptor
    )
        DelegatedTaskAcceptorV1()
        SimpleTimelockedTaskAcceptorV1Proxy(_initialTaskAcceptor, _taskAcceptorUpdateDelay)
        TaskHubV1Notifier()
    {
        bridgingTimeout = _bridgingTimeout;
    }

    function onERC721Received(
        address,
        address _from,
        uint256 _tokenId,
        bytes calldata
    ) external returns (bytes4) {
        if (!bridgingIsApproved(msg.sender)) revert UnsupportedToken();

        TokenDescriptor memory desc = TokenDescriptor({
            token: msg.sender,
            id: _tokenId,
            holder: _from
        });
        knownTokens[getTaskId(desc)] = TokenState({
            bridged: false,
            unlockTimestamp: uint64(block.timestamp + bridgingTimeout)
        });

        taskHub().notify();
        emit BridgingRequested(desc);

        return IERC721Receiver.onERC721Received.selector;
    }

    /// Votes to support a token with all of the tokens held by the caller.
    function supportToken(address _tokenAddr) external {
        SupportedToken storage supported = supportedTokens[_tokenAddr];
        IERC721Enumerable token = IERC721Enumerable(_tokenAddr);

        uint256 newApprovals = 0;
        for (uint256 i; i < token.balanceOf(msg.sender); ++i) {
            uint256 heldTokenId = token.tokenOfOwnerByIndex(msg.sender, i);
            if (supported.voted[heldTokenId]) continue;
            supported.voted[heldTokenId] = true;
            newApprovals += 1;
        }
        supported.approvals += newApprovals;

        if (bridgingIsApproved(_tokenAddr)) emit TokenApproved(_tokenAddr);
    }

    /// Sends a token that is eligible to be reclaimed back to the original sender.
    function reclaimToken(TokenDescriptor calldata _desc) external {
        TokenState storage tokenState = knownTokens[getTaskId(_desc)];
        if (tokenState.bridged) revert AlreadyBridged();
        if (block.timestamp < uint256(tokenState.unlockTimestamp)) revert TooSoon();
        IERC721Enumerable(_desc.token).safeTransferFrom(address(this), _desc.holder, _desc.id);
        emit TokenReclaimed(_desc, msg.sender);
    }

    function proposeToken(address _token) external onlyOwner {
        if (supportedTokens[_token].quorum != 0) return; // Already proposed.
        if (!ERC165Checker.supportsInterface(_token, type(IERC721Enumerable).interfaceId))
            revert UnsupportedToken();
        supportedTokens[_token].quorum = (IERC721Enumerable(_token).totalSupply() >> 1) + 1;
        emit TokenProposed(_token);
    }

    function bridgingIsApproved(address token) public view returns (bool) {
        return supportedTokens[token].approvals >= supportedTokens[token].quorum;
    }

    function getTaskId(TokenDescriptor memory desc) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(desc)));
    }

    function _afterTaskResultsAccepted(
        uint256[] calldata _taskIds,
        bytes calldata,
        address,
        TaskIdSelector memory _sel
    ) internal override {
        uint256[] memory acceptedIxs = _sel.indices(_taskIds);
        for (uint256 i; i < acceptedIxs.length; ++i) {
            TokenState storage tokenState = knownTokens[_taskIds[acceptedIxs[i]]];
            tokenState.bridged = !tokenState.bridged;
            tokenState.unlockTimestamp = 0;
        }
    }
}

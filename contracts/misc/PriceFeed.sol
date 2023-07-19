// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import '../interfaces/IPriceFeed.sol';
import '../interfaces/IFluxAggregator.sol';
import '../dependencies/openzeppelin/contracts/SafeMath.sol';

/*
 * The PriceFeed uses Flux as primary oracle.
 */
contract PriceFeed is IPriceFeed {
  using SafeMath for uint256;

  uint256 public constant DECIMAL_PRECISION = 1e18;

  IFluxAggregator public fluxOracle; // Mainnet Flux aggregator

  // Use to convert a price answer to an 18-digit precision uint
  uint256 public constant TARGET_DIGITS = 18;

  // Maximum time period allowed since Flux's latest round data timestamp, beyond which Flux is considered frozen.
  // For stablecoins we recommend 90000, as Flux updates once per day when there is no significant price movement
  // For volatile assets we recommend 14400 (4 hours)
  uint256 public immutable TIMEOUT;

  // Maximum deviation allowed between two consecutive Flux oracle prices. 18-digit precision.
  uint256 public constant MAX_PRICE_DEVIATION_FROM_PREVIOUS_ROUND = 5e17; // 50%

  /*
   * The maximum relative price difference between two oracle responses allowed in order for the PriceFeed
   * to return to using the Flux oracle. 18-digit precision.
   */
  uint256 public constant MAX_PRICE_DIFFERENCE_BETWEEN_ORACLES = 5e16; // 5%

  // The last good price seen from an oracle by Liquity
  uint256 public lastGoodPrice;

  struct FluxResponse {
    uint80 roundId;
    uint256 answer;
    uint256 timestamp;
    bool success;
    uint8 decimals;
  }

  enum Status {
    fluxWorking,
    fluxUntrusted
  }

  // The current status of the PricFeed, which determines the conditions for the next price fetch attempt
  Status public status;

  event LastGoodPriceUpdated(uint256 _lastGoodPrice);
  event PriceFeedStatusChanged(Status newStatus);

  // --- Dependency setters ---

  constructor(
    IFluxAggregator _fluxOracleAddress,
    uint256 _timeout
  ) {
    fluxOracle = _fluxOracleAddress;

    TIMEOUT = _timeout;

    // Explicitly set initial system status
    status = Status.fluxWorking;

    // Get an initial price from Flux to serve as first reference for lastGoodPrice
    FluxResponse memory fluxResponse = _getCurrentFluxResponse();
    FluxResponse memory prevFluxResponse =
      _getPrevFluxResponse(fluxResponse.roundId, fluxResponse.decimals);

    // TODO: uncomment timeout check for mainnet
    require(
      !_fluxIsBroken(fluxResponse, prevFluxResponse) //&&
        //block.timestamp.sub(fluxResponse.timestamp) < _timeout,
      ,'PriceFeed: Flux must be working and current'
    );

    lastGoodPrice = _scaleFluxPriceByDigits(uint256(fluxResponse.answer), fluxResponse.decimals);
  }

  // --- Functions ---

  /*
   * fetchPrice():
   * Returns the latest price obtained from the Oracle. Called by Liquity functions that require a current price.
   *
   * Also callable by anyone externally.
   *
   * Non-view function - it stores the last good price seen by Liquity.
   *
   * Uses a main oracle (Flux). If it fails,
   * it uses the last good price seen by Liquity.
   *
   */
  function fetchPrice() external view override returns (uint256) {
    (, uint256 price) = _fetchPrice();
    return price;
  }

  function updatePrice() external override returns (uint256) {
    (Status newStatus, uint256 price) = _fetchPrice();
    lastGoodPrice = price;
    if (status != newStatus) {
      status = newStatus;
      emit PriceFeedStatusChanged(newStatus);
    }
    return price;
  }

  function _fetchPrice() internal view returns (Status, uint256) {
    // Get current and previous price data from Flux, and current price data from Band
    FluxResponse memory fluxResponse = _getCurrentFluxResponse();
    FluxResponse memory prevFluxResponse =
      _getPrevFluxResponse(fluxResponse.roundId, fluxResponse.decimals);

    // --- CASE 1: System fetched last price from Flux  ---
    if (status == Status.fluxWorking) {
      // If Flux is broken or frozen
      if (_fluxIsBroken(fluxResponse, prevFluxResponse) || _fluxIsFrozen(fluxResponse)) {
        // If Flux is broken, switch to Band and return current Band price
        return (Status.fluxUntrusted, lastGoodPrice);
      }

      // If Flux price has changed by > 50% between two consecutive rounds
      if (_fluxPriceChangeAboveMax(fluxResponse, prevFluxResponse)) {
        return (Status.fluxUntrusted, fluxResponse.answer);
      }

      // If Flux is working, return Flux current price (no status change)
      return (Status.fluxWorking, fluxResponse.answer);
    }

    // --- CASE 2: Flux oracle is untrusted at the last price fetch ---
    if (status == Status.fluxUntrusted) {
      if (_fluxIsBroken(fluxResponse, prevFluxResponse) || _fluxIsFrozen(fluxResponse)) {
        return (Status.fluxUntrusted, lastGoodPrice);
      }

      return (Status.fluxWorking, fluxResponse.answer);
    }
  }

  // --- Helper functions ---

  /* Flux is considered broken if its current or previous round data is in any way bad. We check the previous round
   * for two reasons:
   *
   * 1) It is necessary data for the price deviation check in case 1,
   * and
   * 2) Flux is the PriceFeed's preferred primary oracle - having two consecutive valid round responses adds
   * peace of mind when using or returning to Flux.
   */
  function _fluxIsBroken(
    FluxResponse memory _currentResponse,
    FluxResponse memory _prevResponse
  ) internal view returns (bool) {
    return _badFluxResponse(_currentResponse) || _badFluxResponse(_prevResponse);
  }

  function _badFluxResponse(FluxResponse memory _response) internal view returns (bool) {
    // Check for response call reverted
    if (!_response.success) {
      return true;
    }
    // Check for an invalid roundId that is 0
    if (_response.roundId == 0) {
      return true;
    }
    // Check for an invalid timeStamp that is 0, or in the future
    if (_response.timestamp == 0 || _response.timestamp > block.timestamp) {
      return true;
    }
    // Check for non-positive price (original value returned from Flux is int256)
    if (int256(_response.answer) <= 0) {
      return true;
    }

    return false;
  }

  function _fluxIsFrozen(FluxResponse memory _response) internal view returns (bool) {
    return block.timestamp.sub(_response.timestamp) > TIMEOUT;
  }

  function _fluxPriceChangeAboveMax(
    FluxResponse memory _currentResponse,
    FluxResponse memory _prevResponse
  ) internal pure returns (bool) {
    uint256 currentScaledPrice = _currentResponse.answer;
    uint256 prevScaledPrice = _prevResponse.answer;

    uint256 minPrice =
      (currentScaledPrice < prevScaledPrice) ? currentScaledPrice : prevScaledPrice;
    uint256 maxPrice =
      (currentScaledPrice >= prevScaledPrice) ? currentScaledPrice : prevScaledPrice;

    /*
     * Use the larger price as the denominator:
     * - If price decreased, the percentage deviation is in relation to the the previous price.
     * - If price increased, the percentage deviation is in relation to the current price.
     */
    uint256 percentDeviation = maxPrice.sub(minPrice).mul(DECIMAL_PRECISION).div(maxPrice);

    // Return true if price has more than doubled, or more than halved.
    return percentDeviation > MAX_PRICE_DEVIATION_FROM_PREVIOUS_ROUND;
  }

  function _scaleFluxPriceByDigits(uint256 _price, uint256 _answerDigits)
    internal
    pure
    returns (uint256)
  {
    /*
     * Convert the price returned by the Flux oracle to an 18-digit decimal for use by Liquity.
     * At date of Liquity launch, Flux uses an 8-digit price, but we also handle the possibility of
     * future changes.
     *
     */
    uint256 price;
    if (_answerDigits >= TARGET_DIGITS) {
      // Scale the returned price value down to Liquity's target precision
      price = _price.div(10**(_answerDigits - TARGET_DIGITS));
    } else if (_answerDigits < TARGET_DIGITS) {
      // Scale the returned price value up to Liquity's target precision
      price = _price.mul(10**(TARGET_DIGITS - _answerDigits));
    }
    return price;
  }

  // --- Oracle response wrapper functions ---

  function _getCurrentFluxResponse()
    internal
    view
    returns (FluxResponse memory fluxResponse)
  {
    // First, try to get current decimal precision:
    try fluxOracle.decimals() returns (uint8 decimals) {
      // If call to Flux succeeds, record the current decimal precision
      fluxResponse.decimals = decimals;
    } catch {
      // If call to Flux aggregator reverts, return a zero response with success = false
      return fluxResponse;
    }

    // Secondly, try to get latest price data:
    try fluxOracle.latestRoundData() returns (
      uint80 roundId,
      int256 answer,
      uint256, /* startedAt */
      uint256 timestamp,
      uint80 /* answeredInRound */
    ) {
      // If call to Flux succeeds, return the response and success = true
      fluxResponse.roundId = roundId;
      fluxResponse.answer = _scaleFluxPriceByDigits(
        uint256(answer),
        fluxResponse.decimals
      );
      fluxResponse.timestamp = timestamp;
      fluxResponse.success = true;
      return fluxResponse;
    } catch {
      // If call to Flux aggregator reverts, return a zero response with success = false
      return fluxResponse;
    }
  }

  function _getPrevFluxResponse(uint80 _currentRoundId, uint8 _currentDecimals)
    internal
    view
    returns (FluxResponse memory prevFluxResponse)
  {
    /*
     * NOTE: Flux only offers a current decimals() value - there is no way to obtain the decimal precision used in a
     * previous round. We assume the decimals used in the previous round are the same as the current round.
     */

    // Try to get the price data from the previous round:
    try fluxOracle.getRoundData(_currentRoundId - 1) returns (
      uint80 roundId,
      int256 answer,
      uint256, /* startedAt */
      uint256 timestamp,
      uint80 /* answeredInRound */
    ) {
      // If call to Flux succeeds, return the response and success = true
      prevFluxResponse.roundId = roundId;
      prevFluxResponse.answer = _scaleFluxPriceByDigits(
        uint256(answer),
        _currentDecimals
      );
      prevFluxResponse.timestamp = timestamp;
      prevFluxResponse.decimals = _currentDecimals;
      prevFluxResponse.success = true;
      return prevFluxResponse;
    } catch {
      // If call to Flux aggregator reverts, return a zero response with success = false
      return prevFluxResponse;
    }
  }
}

-- Written by Neil Schafer
-- Code 5545, US Naval Research Laboratory
-------------------------------------------------------------------------------------------------------------------------
-- Burst Detector Real
--
-- Parameters
-- BitWidth: Bit size of one element of data.
-- coefBitWidth: Size of filter coefficients. Probably 18 for most vendor FPGAs.
-- sampleAddressSpace: The number of bits used to address the BRAM that stores channel estimator values.
--                     Defaults to 10. This means it stores 2^10 = 1024 values. 
--                     For 12 bits of data, this would require 12kbits of RAM.
--                     Powers of 2 are used to make average value calculations cheap.
-- sampleDecimation: Amount of separation between samples added to the channel estimation.
--                   Defaults to 100, meaning the channel estimation is updated only every 100 samples.
--                   For the default case, this means the channel is estimated roughly across 102,400 samples.
--                   Combinations of the sampleDecimation and sampleAddressSpace should consider how much RAM is
--                   available and how long the channel estimator needs to evaluate compared to the length of a burst.
--                   Set to "1" to not discard any samples in the estimation
-- thresholdShiftGain: The amount the incoming signal strength needs to be above the "channel noise" in order to qualify as a burst.
--                     Defaults to 2, meaning incoming signal strength must be 2^2 = 4 times higher than the channel average
--                     to qualify as a burst event. In most cases, this value should probably not be higher than 3.
-- threshold: The value at which energy will qualify as a burst regardless of channel noise.
--            Defaults to 511. Set to 1 if you want all data to pass through (although that implies you shouldn't have a detector at all). 
--            Set to 2^(bitwidth - 1) if you want to ignore this value (~1 in fixed point).
-- burstLength: The number of samples of a burst event (the number of samples provided in the output after a burst is detected).
--              Defaults to 1024.
-- burstHistory: The number of samples before the burst trigger that are also included in the output.
--               Defaults to 0. Low values increase the likelihood of missing burst data. High values increase the likelihood
--               of including extraneous noise. Recommended values are between 0 and number of taps.
-- taps:   The matched filter coefficients. Assumes these are fixed point signed fractions from [-1, 1).
--         To use as an energy detector/basic squelch without a filter at all, 
--         a single coefficient of "2^(bitwidth -1) -1, 0" should be provided. This will act as a multiply by 1, 
--         although the cordic gain of 1.6 will still apply.
--
-- Behavior
-- This component looks for a burst event, and will block all outgoing data until a burst event occurs.
-- Once a burst event is detected, (burstHistory + burstLength) data samples are passed out of the component.
-- A matched filter of at least length one must be provided, and the output of the filter is used to trigger the burst.
-- A "channel estimator" takes samples of the filter output at regular intervals and uses a running average to estimate 
-- the average energy of the channel. A burst is detected when the filter output exceeds the channel energy 
-- by a predetermined amount.

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE WORK.DSP.ALL;

ENTITY BurstDetectorReal IS
    GENERIC(
        bitWidth              : POSITIVE      := DEFAULT_BITWIDTH;
        sampleAddressSpace    : POSITIVE      := DEFAULT_SAMPLE_ADDRESS_SPACE;
        sampleDecimation      : POSITIVE      := DEFAULT_DECIMATION;
        coefBitWidth          : POSITIVE      := DEFAULT_COEF_BITWIDTH;
        averageThresholdShift : NATURAL       := DEFAULT_SHIFT_GAIN;
        taps                  : INTEGER_ARRAY := DEFAULT_BURST_TAPS;
        threshold             : POSITIVE      := DEFAULT_MAX_THRESHOLD;
        burstHistory          : NATURAL       := DEFAULT_HISTORY;
        burstLength           : POSITIVE      := DEFAULT_PACKET_SIZE
    );
    PORT(
        clock   : IN  STD_LOGIC;
        reset   : IN  STD_LOGIC;
        enable  : IN  STD_LOGIC;
        dataIn  : IN  STD_LOGIC_VECTOR(bitWidth - 1 DOWNTO 0);
        valid   : OUT STD_LOGIC;
        dataOut : OUT STD_LOGIC_VECTOR(bitWidth - 1 DOWNTO 0)
    );
END ENTITY BurstDetectorReal;

ARCHITECTURE rtl OF BurstDetectorReal IS
    COMPONENT PolyphaseDecimatingFirFilter IS
        GENERIC(
            Decimation   : POSITIVE;
            CoefBitWidth : POSITIVE;
            BitWidth     : POSITIVE;
            Taps         : INTEGER_ARRAY
        );
        PORT(
            clock   : IN  STD_LOGIC;
            reset   : IN  STD_LOGIC;
            enable  : IN  STD_LOGIC;
            valid   : OUT STD_LOGIC;
            dataIn  : IN  STD_LOGIC_VECTOR(BitWidth - 1 DOWNTO 0);
            dataOut : OUT STD_LOGIC_VECTOR(BitWidth - 1 DOWNTO 0)
        );
    END COMPONENT PolyphaseDecimatingFirFilter;

    COMPONENT MovingAverage IS
        GENERIC(
            bitWidth           : POSITIVE;
            sampleAddressSpace : POSITIVE;
            sampleDecimation   : POSITIVE
        );
        PORT(
            clock   : IN  STD_LOGIC;
            reset   : IN  STD_LOGIC;
            enable  : IN  STD_LOGIC;
            inData  : IN  STD_LOGIC_VECTOR(bitWidth - 1 DOWNTO 0);
            outData : OUT STD_LOGIC_VECTOR(bitWidth - 1 DOWNTO 0);
            valid   : OUT STD_LOGIC
        );
    END COMPONENT MovingAverage;

    COMPONENT PipelineReg IS
        GENERIC(
            pipelineLength : NATURAL;
            bitWidth       : POSITIVE
        );
        PORT(
            reset   : IN  STD_LOGIC;
            clock   : IN  STD_LOGIC;
            enable  : IN  STD_LOGIC;
            dataIn  : IN  STD_LOGIC_VECTOR(bitWidth - 1 DOWNTO 0);
            dataOut : OUT STD_LOGIC_VECTOR(bitWidth - 1 DOWNTO 0);
            valid   : OUT STD_LOGIC
        );
    END COMPONENT PipelineReg;

    CONSTANT nonDecimation     : POSITIVE := 1;
    CONSTANT pipelineDelay     : POSITIVE := 6; -- Internals have 6 clock latency
    CONSTANT filterDelay       : POSITIVE := burstHistory + pipelineDelay;
    CONSTANT totalSamples      : POSITIVE := burstHistory + burstLength;
    SIGNAL filterResult        : STD_LOGIC_VECTOR(bitWidth - 1 DOWNTO 0);
    SIGNAL absFilterResult     : STD_LOGIC_VECTOR(bitWidth - 1 DOWNTO 0);
    SIGNAL averageOut          : STD_LOGIC_VECTOR(bitWidth - 1 DOWNTO 0);
    SIGNAL shiftedAverage      : STD_LOGIC_VECTOR(bitWidth + averageThresholdShift - 1 DOWNTO 0);
    SIGNAL validOut            : STD_LOGIC;
    SIGNAL counter             : NATURAL RANGE 0 TO totalSamples;
    SIGNAL validFilterOut      : STD_LOGIC;
    SIGNAL validDelayOut       : STD_LOGIC;
    SIGNAL movingAverageEnable : STD_LOGIC;
    SIGNAL validMovingAverage  : STD_LOGIC;

BEGIN
    matchedFilter : PolyphaseDecimatingFirFilter
        GENERIC MAP(
            decimation   => nonDecimation,
            coefBitWidth => coefBitWidth,
            bitWidth     => bitWidth,
            taps         => taps
        )
        PORT MAP(
            clock   => clock,
            reset   => reset,
            enable  => enable,
            valid   => validFilterOut,
            dataIn  => dataIn,
            dataOut => filterResult
        );

    absFilterResult <= STD_LOGIC_VECTOR(ABS (signed(filterResult)));

    delay : PipelineReg
        GENERIC MAP(
            pipelineLength => filterDelay,
            bitWidth       => bitWidth
        )
        PORT MAP(
            reset   => reset,
            clock   => clock,
            enable  => enable,
            dataIn  => dataIn,
            dataOut => dataOut,
            valid   => validDelayOut
        );

    movingAverageEnable <= validFilterOut;

    avg : MovingAverage
        GENERIC MAP(
            bitWidth           => bitWidth,
            sampleAddressSpace => sampleAddressSpace,
            sampleDecimation   => sampleDecimation
        )
        PORT MAP(
            clock   => clock,
            reset   => reset,
            enable  => movingAverageEnable,
            inData  => absFilterResult,
            outData => averageOut,
            valid   => validMovingAverage
        );
    shiftedAverage(shiftedAverage'high DOWNTO averageThresholdShift) <= averageOut;
    shiftedAverage(averageThresholdShift - 1 DOWNTO 0)               <= (OTHERS => '0');

    validOut <= '1' WHEN (unsigned(absFilterResult) > unsigned(shiftedAverage)) AND validMovingAverage = '1'
        ELSE '1' WHEN (unsigned(absFilterResult) >= threshold) AND validFilterOut = '1'
        ELSE '0';

    valid <= '1' WHEN (validDelayOut = '1' AND reset = '0' AND counter > 0)
        ELSE '0';

    PROCESS(clock)
    BEGIN
        IF (rising_edge(clock)) THEN
            IF (reset = '1') THEN
                counter <= 0;
            ELSIF (validDelayOut = '1') THEN
                IF (validOut = '1' AND counter = 0) THEN
                    counter <= totalSamples;
                ELSIF (counter > 0) THEN
                    counter <= counter - 1;
                END IF;
            END IF;
        END IF;
    END PROCESS;

END ARCHITECTURE rtl;

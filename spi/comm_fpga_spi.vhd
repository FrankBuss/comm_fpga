library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity comm_fpga_spi is
	port(
		-- system clock
		clock          : in    std_logic;

		-- Microcontroller SPI interface
		-- Protocol:
		-- A transfer starts with falling edge of cs. The FPGA samples mosi on falling edge of sck,
		-- and the microcontroller should sample miso on falling edge of sck, too
		-- (CPOL=0, CPHA=1 mode for LPC11U24). Data is shifted MSB first.
		--
		-- The first byte of a transfer is the channel number. Bit 7 is cleared, when the
		-- host sends data to the channel. Bit 7 is set, when the host receives data from
		-- the channel.
		--
		-- When the host wants to read data, the second byte is unused to give the FPGA time to
		-- setup the first byte, then it reads the channel with each subsequent byte.
		-- The maximum allowed frequency for sck is clock/5.
		mosi: in std_logic;
		miso: out std_logic;
		cs: in std_logic;
		sck: in std_logic;

		-- Channel read/write interface --------------------------------------------------------------
		chanAddr_out   : out   std_logic_vector(6 downto 0);  -- the selected channel (0-127), valid with start = '1'
		chanWrite_out  : out   std_logic;                     -- '1', if the host wants to write to the channel, valid with start = '1'
		start          : out   std_logic;                     -- '1' (for one clock cycle) means, that a new read write transaction started

		-- Host >> FPGA pipe:
		h2fData_out    : out   std_logic_vector(7 downto 0);  -- data lines used when the host writes to a channel
		h2fValid_out   : out   std_logic;                     -- '1' means "on the next clock rising edge, please accept the data on h2fData_out"

		-- Host << FPGA pipe:
		f2hData_in     : in    std_logic_vector(7 downto 0);  -- data lines used when the host reads from a channel
		f2hReady_out   : out   std_logic                      -- '1' means "on the next clock rising edge, put your next byte of data on f2hData_in"
	);
end comm_fpga_spi;

architecture rtl of comm_fpga_spi is
	-- input latches
	signal mosiLatch: std_logic;
	signal csLatch: std_logic;
	signal sckLatch: std_logic;

	-- SPI communication
	signal csEdgeDetect: std_logic_vector(1 downto 0);
	signal sckEdgeDetect: std_logic_vector(1 downto 0);
	signal dataBitCounter: natural range 0 to 8;
	signal data: std_logic_vector(7 downto 0);
	signal byteReceived: boolean := false;

	-- SPI states
	type SpiStateType is (
		idle,
		fpga2host_waitForByte,
		fpga2host_nextByte1,
		fpga2host_nextByte2,
		host2fpga
	);
	signal spiState: SpiStateType := idle;
	
begin

	process(clock)
	begin
		if rising_edge(clock) then
			-- default values
			start <= '0';
			h2fValid_out <= '0';
			f2hReady_out <= '0';
			chanWrite_out <= '0';
			byteReceived <= false;

			-- latch input signals
			mosiLatch <= mosi;
			csLatch <= cs;
			sckLatch <= sck;
			csEdgeDetect <= csEdgeDetect(0) & csLatch;
			sckEdgeDetect <= sckEdgeDetect(0) & sckLatch;

			-- start communication on falling CS edge
			if csEdgeDetect = "10" then
				dataBitCounter <= 0;
				miso <= '0';
				spiState <= idle;
			end if;
			
			-- stop communication on rising CS edge
			if csEdgeDetect = "01" then
				spiState <= idle;
			end if;
			
			case spiState is

				-- wait for first SPI byte, which is the channel address
				when idle =>
					if byteReceived then
						start <= '1';
						chanAddr_out <= data(6 downto 0);
						if data(7) = '1' then
							chanWrite_out <= '0';
 							spiState <= fpga2host_waitForByte;
						else
							chanWrite_out <= '1';
							spiState <= host2fpga;
						end if;
					end if;
					
				-- wait for next unused byte from SPI, then request byte from FPGA
				when fpga2host_waitForByte =>
					if byteReceived then
						f2hReady_out <= '1';
						spiState <= fpga2host_nextByte1;
					end if;
					
				-- parent entity puts the byte of data on f2hData_in
				when fpga2host_nextByte1 =>
					spiState <= fpga2host_nextByte2;
					
				-- set received byte from FPGA for sending with the next unused byte from SPI
				when fpga2host_nextByte2 =>
					data <= f2hData_in;
					spiState <= fpga2host_waitForByte;
					
				-- transfer received byte from host, to FPGA
				when host2fpga =>
					if byteReceived then
						h2fData_out <= data;
						h2fValid_out <= '1';
					end if;
			end case;
				
			-- output SPI data on rising edge
			if sckEdgeDetect(0) = '0' and sckLatch = '1' then
				miso <= data(7);
			end if;

			-- sample MOSI on falling edge
			if sckEdgeDetect = "10" then
				data <= data(6 downto 0) & mosiLatch;
				dataBitCounter <= dataBitCounter + 1;
			end if;

			if dataBitCounter = 8 then
				dataBitCounter <= 0;
				byteReceived <= true;
			end if;
		end if;

	end process;

end architecture rtl;

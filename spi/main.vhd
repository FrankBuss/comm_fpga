library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity main is
	port(
		-- misc signals
		clock12mhz: in std_logic;
			
		-- RAM
		ram_a: out std_logic_vector(21 downto 0);
		ram_dq: inout  std_logic_vector(15 downto 0);
		ram_cs1: out std_logic;
		ram_cs2: out std_logic;
		ram_we: out std_logic;
		ram_oe: out std_logic;
		ram_lb: out std_logic;
		ram_ub: out std_logic;
		ram_byte: out std_logic;
		
		-- microcontroller SPI interface
		spiMosi: in std_logic;
		spiMiso: out std_logic;
		spiCS: in std_logic;
		spiClock: in std_logic
	);
end main;

architecture rtl of main is
	signal clock96mhz: std_logic;

	-- SRAM
	type RamStateType is (
		idle,
		readStart,
		writeStart,
		ramEnd
	);
	signal ramState: RamStateType := idle;
	signal ramDelay: natural range 0 to 15;
	signal ramWriteRequest: boolean := false;
	signal ramReadRequest: boolean := false;
	signal ramWriteData: std_logic_vector(7 downto 0);
	signal ramReadResult: std_logic_vector(7 downto 0);
	signal ramAddress: std_logic_vector(22 downto 0);
	
	-- host communication interface
	signal commChanAddr: std_logic_vector(6 downto 0);
	signal commChanWrite: std_logic;
	signal commStart: std_logic;
	signal commH2fData: std_logic_vector(7 downto 0);
	signal commH2fValid: std_logic;
	signal commF2hData: std_logic_vector(7 downto 0);
	signal commF2hReady: std_logic;
	signal shiftRegister: std_logic_vector(31 downto 0);
	type CommStateType is (
		idle,
		writeControlRegister,
		readStatusRegister,
		writeRAM,
		readRAM
	);
	signal commState: CommStateType := idle;
	signal byteCount: natural range 0 to 4;

	-- the host can write this register to control the FPGA
	signal controlRegister: std_logic_vector(31 downto 0) := (others => '0');

	-- the host can read this register to get status information about the FPGA
	signal statusRegister: std_logic_vector(31 downto 0) := (others => '0');
	
begin

	clock_inst: entity clock
		port map(
	        CLKI => clock12mhz,
			CLKOP => clock96mhz
		);

	comm_fpga_spi_inst: entity comm_fpga_spi
		port map(
			clock => clock96mhz,
			mosi => spiMosi,
			miso => spiMiso,
			cs => spiCS,
			sck => spiClock,
			chanAddr_out => commChanAddr,
			chanWrite_out => commChanWrite,
			start => commStart,
			h2fData_out => commH2fData,
			h2fValid_out => commH2fValid,
			f2hData_in => commF2hData,
			f2hReady_out => commF2hReady
	);
		
	SRAM_read_write: process(clock96mhz)
	begin
		if rising_edge(clock96mhz) then
			case ramState is
				when idle =>
					ram_cs1 <= '1';
					ram_we <= '1';
					ram_oe <= '1';
					ram_dq(7 downto 0) <= (others => '0');
					if ramReadRequest then
						ram_oe <= '0';
						ram_cs1 <= '0';
						ram_a <= ramAddress(22 downto 1);
						ram_dq(7 downto 0) <= (others => 'Z');
						ram_dq(15) <= ramAddress(0);
						ramDelay <= 15;
						ramState <= readStart;
					end if;
					if ramWriteRequest then
						ram_we <= '0';
						ram_cs1 <= '0';
						ram_a <= ramAddress(22 downto 1);
						ram_dq(7 downto 0) <= ramWriteData;
						ram_dq(15) <= ramAddress(0);
						ramDelay <= 15;
						ramState <= writeStart;
					end if;
				when readStart =>
					if ramDelay = 0 then
						ramReadResult <= ram_dq(7 downto 0);
						ram_oe <= '1';
						ram_cs1 <= '1';
						ramDelay <= 15;
						ramState <= ramEnd;
					else
						ramDelay <= ramDelay - 1;
					end if;
				when ramEnd =>
					if ramDelay = 0 then
						ramState <= idle;
					else
						ramDelay <= ramDelay - 1;
					end if;
				when writeStart =>
					if ramDelay = 0 then
						ram_we <= '1';
						ram_cs1 <= '1';
						ramDelay <= 15;
						ramState <= ramEnd;
					else
						ramDelay <= ramDelay - 1;
					end if;
			end case;
		end if;
	end process;
	
	control: process(clock96mhz)
	begin
		if rising_edge(clock96mhz) then
			-- default values
			ramReadRequest <= false;
			ramWriteRequest <= false;

			if commStart = '1' then
				case commChanAddr is
					when std_logic_vector(to_unsigned(0, 7)) =>
						byteCount <= 0;
						if commChanWrite = '1' then
							commState <= writeControlRegister;
						else
							shiftRegister <= statusRegister;
							commState <= readStatusRegister;
						end if;
					when std_logic_vector(to_unsigned(1, 7)) =>
						ramAddress <= (others => '1');
						if commChanWrite = '1' then
							ramAddress <= (others => '1');
							commState <= writeRAM;
						else
							ramAddress <= (others => '0');
							ramReadRequest <= true;
							commState <= readRAM;
						end if;
					when others => null;
				end case;
			end if;

			case commState is
				when idle => null;

				when writeControlRegister =>
					-- update control register when 4 bytes were received, then back to idle
					if byteCount = 4 then
						controlRegister <= shiftRegister;
						commState <= idle;
					end if;

					-- host writes data to the control register
					if commH2fValid = '1' then
						shiftRegister <= shiftRegister(23 downto 0) & commH2fData;
						byteCount <= byteCount + 1;
					end if;

				when readStatusRegister =>
					-- back to idle, when 4 bytes were received
					if byteCount = 4 then
						commState <= idle;
					end if;

					-- host reads data from the status register
					if commF2hReady = '1' then
						commF2hData <= shiftRegister(31 downto 24);
						shiftRegister <= shiftRegister(23 downto 0) & x"00";
						byteCount <= byteCount + 1;
					end if;

				when writeRAM =>
					-- host writes to RAM
					if commH2fValid = '1' then
						ramWriteRequest <= true;
						ramWriteData <= commH2fData;
						ramAddress <= std_logic_vector(unsigned(ramAddress) + 1);
					end if;

				when readRAM =>
					-- host reads from RAM
					if commF2hReady = '1' then
						commF2hData <= ramReadResult;
						ramReadRequest <= true;
						ramAddress <= std_logic_vector(unsigned(ramAddress) + 1);
					end if;
			end case;
			
			-- copy control register to status register for testing the communication
			statusRegister <= controlRegister;
				
		end if;

	end process;

	-- SRAM configuration: byte mode (DQ8..DQ14 are unused, DQ15 is address bit -1), select with cs1
	ram_cs2 <= '1';
	ram_lb <= '0';
	ram_ub <= '0';
	ram_byte <= '0';

	-- testing
	ram_dq(8) <= not spiClock;
	ram_dq(9) <= clock96mhz;
	ram_dq(10) <= clock12mhz;
	ram_dq(11) <= '1';
	ram_dq(12) <= '1';
	ram_dq(13) <= '1';
	ram_dq(14) <= '1';
	
end architecture rtl;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity power_on_demo_top is
    generic (
        CLK_HZ : integer := 30000000
    );
    port (
        clk_30m    : in  std_logic;

        key_sw     : in  std_logic_vector(6 downto 0);   -- Low active
        toggle_sw  : in  std_logic_vector(12 downto 0);  -- Low active
        rotary_dip : in  std_logic_vector(3 downto 0);   -- Low active

        led24      : out std_logic_vector(23 downto 0);  -- '1'で点灯
        seg_h      : out std_logic_vector(6 downto 0);   -- active High, abcdefg
        scan_h     : out std_logic_vector(7 downto 0)    -- active High
    );
end entity;

architecture rtl of power_on_demo_top is

    constant ONE_SEC_MAX  : integer := CLK_HZ - 1;
    constant SCAN_DIV_MAX : integer := CLK_HZ / 1000 - 1;
    constant INIT_WAIT_MAX : integer := CLK_HZ / 100; -- 10ms

    type mode_t is (
        MODE_DEMO,
        MODE_HOLD,
        MODE_TOGGLE_VIEW,
        MODE_ROTARY_VIEW
    );

    type digit_array_t is array (0 to 7) of std_logic_vector(3 downto 0);

    signal mode : mode_t := MODE_DEMO;

    signal init_cnt  : integer range 0 to INIT_WAIT_MAX := 0;
    signal init_done : std_logic := '0';

    signal one_sec_cnt  : integer range 0 to ONE_SEC_MAX := 0;
    signal one_sec_tick : std_logic := '0';

    signal scan_cnt : integer range 0 to SCAN_DIV_MAX := 0;
    signal scan_pos : integer range 0 to 7 := 0;

    signal key_ff1, key_ff2  : std_logic_vector(6 downto 0) := (others => '1');
    signal key_prev          : std_logic_vector(6 downto 0) := (others => '1');
    signal key_press_pulse   : std_logic := '0';

    signal sw_ff1, sw_ff2    : std_logic_vector(12 downto 0) := (others => '1');
    signal sw_logic          : std_logic_vector(12 downto 0) := (others => '1');
    signal sw_prev           : std_logic_vector(12 downto 0) := (others => '1');
    signal sw_change_pulse   : std_logic := '0';

    signal rot_ff1, rot_ff2  : std_logic_vector(3 downto 0) := (others => '1');
    signal rot_logic         : std_logic_vector(3 downto 0) := (others => '0');
    signal rot_prev          : std_logic_vector(3 downto 0) := (others => '0');
    signal rot_change_pulse  : std_logic := '0';

    signal hex_digit : unsigned(3 downto 0) := (others => '0');
    signal led_phase : std_logic := '0';

    signal toggle_latched : std_logic_vector(12 downto 0) := (others => '0');
    signal rotary_latched : std_logic_vector(3 downto 0)  := (others => '0');

    signal digits : digit_array_t := (others => (others => '0'));

    function hex_to_7seg_abcdefg(
        h : std_logic_vector(3 downto 0)
    ) return std_logic_vector is
        variable s : std_logic_vector(6 downto 0);
    begin
        -- active High, abcdefg
        case h is
            when x"0" => s := "1111110";
            when x"1" => s := "0110000";
            when x"2" => s := "1101101";
            when x"3" => s := "1111001";
            when x"4" => s := "0110011";
            when x"5" => s := "1011011";
            when x"6" => s := "1011111";
            when x"7" => s := "1110000";
            when x"8" => s := "1111111";
            when x"9" => s := "1111011";
            when x"A" => s := "1110111";
            when x"B" => s := "0011111";
            when x"C" => s := "1001110";
            when x"D" => s := "0111101";
            when x"E" => s := "1001111";
            when others => s := "1000111"; -- F
        end case;
        return s;
    end function;

begin

    --------------------------------------------------------------------
    -- トグルSWは反転しない
    -- ロータリーDIPはLow activeとして反転する
    --------------------------------------------------------------------
    sw_logic  <= sw_ff2;
    rot_logic <= not rot_ff2;

    --------------------------------------------------------------------
    -- 1秒タイマ
    --------------------------------------------------------------------
    process(clk_30m)
    begin
        if rising_edge(clk_30m) then
            if one_sec_cnt = ONE_SEC_MAX then
                one_sec_cnt  <= 0;
                one_sec_tick <= '1';
            else
                one_sec_cnt  <= one_sec_cnt + 1;
                one_sec_tick <= '0';
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- ダイナミック点灯スキャン
    --------------------------------------------------------------------
    process(clk_30m)
    begin
        if rising_edge(clk_30m) then
            if scan_cnt = SCAN_DIV_MAX then
                scan_cnt <= 0;

                if scan_pos = 7 then
                    scan_pos <= 0;
                else
                    scan_pos <= scan_pos + 1;
                end if;
            else
                scan_cnt <= scan_cnt + 1;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- 入力同期化・変化検出
    --------------------------------------------------------------------
    process(clk_30m)
        variable key_now_pressed  : std_logic;
        variable key_prev_pressed : std_logic;
    begin
        if rising_edge(clk_30m) then

            key_ff1 <= key_sw;
            key_ff2 <= key_ff1;

            sw_ff1 <= toggle_sw;
            sw_ff2 <= sw_ff1;

            rot_ff1 <= rotary_dip;
            rot_ff2 <= rot_ff1;

            key_now_pressed  := '0';
            key_prev_pressed := '0';

            for i in 0 to 6 loop
                if key_ff2(i) = '0' then
                    key_now_pressed := '1';
                end if;

                if key_prev(i) = '0' then
                    key_prev_pressed := '1';
                end if;
            end loop;

            if key_now_pressed = '1' and key_prev_pressed = '0' then
                key_press_pulse <= '1';
            else
                key_press_pulse <= '0';
            end if;

            key_prev <= key_ff2;

            ----------------------------------------------------------------
            -- 起動直後は入力同期FFが実入力に追いつくまで変化検出しない
            -- 10ms後の値を初期状態として記憶し、以降の変化だけを検出する
            ----------------------------------------------------------------
            if init_done = '0' then
                sw_change_pulse  <= '0';
                rot_change_pulse <= '0';

                if init_cnt = INIT_WAIT_MAX then
                    init_done <= '1';
                    sw_prev   <= sw_logic;   -- トグルSWは反転しない
                    rot_prev  <= rot_logic;  -- ロータリーDIPは反転後の論理値
                else
                    init_cnt <= init_cnt + 1;
                end if;

            else
                if sw_logic /= sw_prev then
                    sw_change_pulse <= '1';
                    sw_prev <= sw_logic;
                else
                    sw_change_pulse <= '0';
                end if;

                if rot_logic /= rot_prev then
                    rot_change_pulse <= '1';
                    rot_prev <= rot_logic;
                else
                    rot_change_pulse <= '0';
                end if;
            end if;

        end if;
    end process;

    --------------------------------------------------------------------
    -- メイン状態制御
    --------------------------------------------------------------------
    process(clk_30m)
    begin
        if rising_edge(clk_30m) then

            if rot_change_pulse = '1' then
                rotary_latched <= rot_logic;
                mode <= MODE_ROTARY_VIEW;

            elsif sw_change_pulse = '1' then
                toggle_latched <= sw_logic;
                mode <= MODE_TOGGLE_VIEW;

            elsif key_press_pulse = '1' then
                case mode is
                    when MODE_DEMO =>
                        mode <= MODE_HOLD;

                    when MODE_HOLD =>
                        mode <= MODE_DEMO;

                    when MODE_TOGGLE_VIEW =>
                        mode <= MODE_DEMO;

                    when MODE_ROTARY_VIEW =>
                        mode <= MODE_DEMO;
                end case;

            elsif one_sec_tick = '1' then
                if mode = MODE_DEMO then
                    hex_digit <= hex_digit + 1;
                    led_phase <= not led_phase;
                end if;
            end if;

        end if;
    end process;

    --------------------------------------------------------------------
    -- 8桁表示データ生成
    --------------------------------------------------------------------
    process(mode, hex_digit, toggle_latched, rotary_latched)
        variable toggle16 : std_logic_vector(15 downto 0);
    begin
        toggle16 := "000" & toggle_latched;

        case mode is

            when MODE_DEMO =>
                for i in 0 to 7 loop
                    digits(i) <= std_logic_vector(hex_digit);
                end loop;

            when MODE_HOLD =>
                for i in 0 to 7 loop
                    digits(i) <= std_logic_vector(hex_digit);
                end loop;

            when MODE_TOGGLE_VIEW =>
                digits(0) <= toggle16(3 downto 0);
                digits(1) <= toggle16(7 downto 4);
                digits(2) <= toggle16(11 downto 8);
                digits(3) <= toggle16(15 downto 12);
                digits(4) <= x"0";
                digits(5) <= x"0";
                digits(6) <= x"0";
                digits(7) <= x"0";

            when MODE_ROTARY_VIEW =>
                for i in 0 to 7 loop
                    digits(i) <= rotary_latched;
                end loop;

        end case;
    end process;

    --------------------------------------------------------------------
    -- LED
    --------------------------------------------------------------------
    process(led_phase)
    begin
        if led_phase = '0' then
            led24 <= x"555555";
        else
            led24 <= x"AAAAAA";
        end if;
    end process;

    --------------------------------------------------------------------
    -- 7セグ出力
    -- digits(0) = 右端桁
    -- digits(7) = 左端桁
    --------------------------------------------------------------------
    process(scan_pos, digits)
    begin
        scan_h <= (others => '0');
        scan_h(scan_pos) <= '1';

        seg_h <= hex_to_7seg_abcdefg(digits(scan_pos));
    end process;

end architecture;

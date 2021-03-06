staload "interrupts.sats"
staload "portio.sats"
staload GDT = "gdt.sats"
staload "trace.sats"

(* PIC registers *)
#define PIC1_CMD 0x20
#define PIC1_DATA 0x21
#define PIC2_CMD 0xA0
#define PIC2_DATA 0xA1

(* PIC commands *)
#define PIC_ACK 0x20
#define ICW1_ICW4 0x01
#define ICW1_SINGLE 0x02
#define ICW1_INTERVAL4 0x04
#define ICW1_LEVEL 0x08
#define ICW1_INIT 0x10
#define ICW4_8086 0x01
#define ICW4_AUTO 0x02
#define ICW4_BUF_SLAVE 0x08
#define ICW4_BUF_MASTER 0x0C
#define ICW4_SFNM 0x10

typedef interrupt_descriptor = @( uint16, uint16, uint16, uint16 )

%{^
  extern void (*interrupt_handlers[])();
  struct { uint16_t a,b,c,d; } the_idt[256];
%}

val (pf_interrupt_handlers | interrupt_handlers) =
  $extval ([l: agz] (vbox (@[interrupt_handler][256] @ l) | ptr l),
           "interrupt_handlers")

val (pf_the_idt | the_idt) =
  $extval ([l: agz] (vbox (@[interrupt_descriptor][256] @ l) | ptr l),
           "the_idt")

fn default_interrupt_handler
  (vector: interrupt_vector,
   stack: &interrupt_stack):<!ntm,!ref> void =
begin
  trace "tick ";
  if vector >= 0x20 && vector < 0x30 then
    ack_irq (irq_of_vector vector)
end

%{^
  static void lidt (void *idt)
  {
    __asm__ volatile (
      "subl $6,%%esp         \n"
      "movw %%cx,(%%esp)     \n"
      "movl %%eax,2(%%esp)   \n"
      "lidt (%%esp)          \n"
      "addl $6,%%esp         \n"
      :: "c" (256*8), "a" (idt)
      : "cc"
    );
  }
%}

extern fun lidt {l: agz}
  (pf: !(@[interrupt_descriptor][256] @ l) |
   p: ptr l):<> void = "lidt"

fn w {x: Uint16} (x: int x):<> uint16 = uint16_of (uint1_of x)
fn b {x: Uint8} (x: int x):<> uint8 = uint8_of (uint1_of x)

fn remap_pics ():<> void =
let
  val pic1_offset = 0x20
  val pic2_offset = 0x28
in
  outb (w PIC1_CMD, b (ICW1_INIT + ICW1_ICW4)); io_wait ();
  outb (w PIC2_CMD, b (ICW1_INIT + ICW1_ICW4)); io_wait ();
  outb (w PIC1_DATA, b pic1_offset); io_wait ();
  outb (w PIC2_DATA, b pic2_offset); io_wait ();
  outb (w PIC1_DATA, b 4); io_wait ();
  outb (w PIC2_DATA, b 2); io_wait ();
  outb (w PIC1_DATA, b ICW4_8086); io_wait ();
  outb (w PIC2_DATA, b ICW4_8086); io_wait ();
  outb (w PIC1_DATA, b 0xFF);
  outb (w PIC2_DATA, b 0xFF)
end

implement init () =
begin
  // Fill in the IDT and handler table.
  let var i: Int in
    for* {i: nat | i <= 256} .<256-i>. (i: int i)
    => (i := 0; i < 256; i := i + 1)
    begin
      let
        // Get isr address from interrupt handler table.
        val isr_address = uintptr_of_handler (
          let prval vbox pf_interrupt_handlers = pf_interrupt_handlers in
            interrupt_handlers->[i]
          end) where {
            extern castfn uintptr_of_handler (x: interrupt_handler):<> [x: Uintptr] uintptr_t x
          }
        prval vbox pf_the_idt = pf_the_idt
      in
        // Create IDT entry.
        the_idt->[i] := @(
          uint16_of (uint1_of (isr_address land uintptr1_of 0xFFFFu)),
          w $GDT.SEG_DPL0_CODE,
          w 0x8E00,
          uint16_of (uint1_of ((isr_address >> 16) land uintptr1_of 0xFFFFu))
        );
      end;
      let prval vbox pf_interrupt_handlers = pf_interrupt_handlers in
        // Set interrupt handler table entry to the default interrupt handler.
        interrupt_handlers->[i] := default_interrupt_handler
      end
    end
  end;
  trace "IDT ";
  let prval vbox pf_the_idt = pf_the_idt in
    lidt (pf_the_idt | the_idt)
  end;
  trace "PIC ";
  remap_pics ();
  // Enable the cascade IRQ so that the slave PIC can work.
  unmask_irq 2
end

implement set_handler (vector, handler) =
let prval vbox pf_interrupt_handlers = pf_interrupt_handlers in
  interrupt_handlers->[vector] := handler
end

implement clear_handler (vector) =
let prval vbox pf_interrupt_handlers = pf_interrupt_handlers in
  interrupt_handlers->[vector] := default_interrupt_handler
end

implement vector_of_irq (irq) = irq + 0x20
implement irq_of_vector (vector) = vector - 0x20

prval SHL_1_7: SHL (1, 7, 128) = (,(pf_exp2_const 7), MULind(MULbas()))

implement unmask_irq ([irq: int] irq) =
  if irq < 8 then begin
    (* Master PIC *)
    let
      val a = inb (w PIC1_DATA)
      prval pf_bit = SHL_make {1, irq} ()
      prval () = SHL_le (pf_bit, SHL_1_7)
      val bit = ushl (pf_bit | 1u, irq)
      val a = a land ~ uint8_of bit
      val () = outb (w PIC1_DATA, a)
    in () end
  end else begin
    (* Slave PIC *)
    let
      val a = inb (w PIC2_DATA)
      prval pf_bit = SHL_make {1,irq-8} ()
      prval () = SHL_le (pf_bit, SHL_1_7)
      val bit = ushl (pf_bit | 1u, irq-8)
      val a = a land ~ uint8_of bit
      val () = outb (w PIC2_DATA, a)
    in () end
  end

implement mask_irq ([irq: int] irq) =
  if irq < 8 then begin
    (* Master PIC *)
    let
      val a = inb (w PIC1_DATA)
      prval pf_bit = SHL_make {1, irq} ()
      prval () = SHL_le (pf_bit, SHL_1_7)
      val bit = ushl (pf_bit | 1u, irq)
      val a = a lor uint8_of bit
      val () = outb (w PIC1_DATA, a)
    in () end
  end else begin
    (* Slave PIC *)
    let
      val a = inb (w PIC2_DATA)
      prval pf_bit = SHL_make {1,irq-8} ()
      prval () = SHL_le (pf_bit, SHL_1_7)
      val bit = ushl (pf_bit | 1u, irq-8)
      val a = a lor uint8_of bit
      val () = outb (w PIC2_DATA, a)
    in () end
  end

implement ack_irq (n) =
begin
  if n >= 8 then outb (w PIC2_CMD, b PIC_ACK);
  outb (w PIC1_CMD, b PIC_ACK)
end

# DVCon Rehearsal

**30 August 2026.** Two scripts, the questions each one invites, and how to
handle the three kinds of person who will stop at the booth.

Read the scripts aloud. Record yourself once. The gap between what reads well
and what *says* well is larger than it looks, and you will hear it immediately.

---

## The 20-second version

This is not a summary of the 90-second version. Its only job is to **earn** the
90 seconds. It names the domain so the listener can tell whether they care, then
gives one specific surprising thing.

> "AXI4-Lite verification &mdash; UVM environment, SVA assertions, the usual
> stack. The thing worth telling you: I injected a protocol violation into my
> own driver. Every functional check still passed and UVM reported zero errors.
> Only the bound assertion caught it."

**40 words. About 16 seconds at a normal pace, 13 if you rush.** Then stop talking.

Stopping is the hard part. The silence is doing work &mdash; if they are
interested they will ask, and a question you answer is worth five times a
paragraph you volunteered.

### Why this one and not something else

- It is **specific**. "I built a UVM testbench" is what everyone says.
- It is **surprising**. Everything passing while the bus was driven illegally is
  counter-intuitive, and counter-intuitive is memorable.
- It **implies competence without claiming it**. Someone who has injected a
  defect into their own driver has thought harder than someone who has not.
- It **invites exactly one obvious question** &mdash; *"how did you catch it,
  then?"* &mdash; and the answer is scripted below, in two sentences. Withholding
  the *how* is the point: it hands them the next move.

### If they don't bite

Fine. Not everyone is looking. Hand them the one-pager and let them go. Do not
follow a disengaged person into the 90-second version.

---

## The 90-second version

236 words. That is 79 seconds at a fast pace and 94 at a measured one, so
there is slack in both directions -- nerves speeding you up will not wreck it,
and slowing down for the findings still lands under 95.

> "I built a UVM verification environment for an AXI4-Lite peripheral subsystem
> &mdash; a register file with mixed read-write, read-only and write-one-to-clear
> policies, and a small memory. The RTL is deliberately small. The effort went
> into the methodology.
>
> There's a written verification plan that predates the code, twenty-three SVA
> assertions bound to the design, a constrained-random driver running independent
> per-channel threads, a passive monitor that rebuilds transactions from pins
> only, and a scoreboard whose reference model comes from the specification
> rather than from the RTL.
>
> What I'd actually tell you about is what it found.
>
> I had a cover property meant to prove my driver's threads were genuinely
> independent. It was passing &mdash; but it was written so that it *couldn't*
> fail. Any multi-transaction run satisfied it. Qualifying it properly dropped
> the hit count from ten to one on identical stimulus.
>
> Then I broke my own design on purpose to prove the checker caught it, and ran
> it three ways. Bound assertion: caught at the moment of violation. No
> assertion: caught twelve checks later, as data corruption. Bound assertion with
> one stimulus case removed: thirty-one of thirty-one checks passed &mdash; on a
> broken design.
>
> It's in progress. No interconnect yet, no RAL, and three coverage groups I've
> listed as unmodelled rather than faked. Every number I've quoted came from a
> run."

### The three beats

1. **What it is** &mdash; 20s. Get past it quickly; it is the least interesting part.
2. **What it found** &mdash; 50s. This is the whole pitch. Slow down here.
3. **What it isn't** &mdash; 15s. The scope admission is not modesty, it is
   credibility. It also pre-empts the challenge they were forming.

### Where to cut if you are losing them

Drop the second finding and land on the scope sentence. The cover-property story
alone is enough, and a 60-second version delivered to an engaged listener beats
90 seconds delivered to a polite one.

---

## Follow-ups to the 20-second version

The short version deliberately withholds the *how*. These four are what it
provokes, and they need short answers &mdash; you are still in the first minute
and a paragraph here loses the room.

### "How did you catch it, then?" / "What caught it?"

The single most likely question in the whole booth. Answer it in two sentences.

> "An assertion bound to the design. AXI says once you assert VALID you can't
> withdraw it until the slave has accepted &mdash; my driver withdrew it a cycle
> early, so the assertion fired three times while every data check came back
> clean."

If they want more, *then* explain the window: the slave holds READY high when
it's idle, so you only get a violation in the cycle after an accept, when READY
drops.

### "Why did everything else pass?"

> "Because the slave tolerated the malformed handshake and still returned the
> right data. Reading back what you wrote proves the data path works &mdash; it
> says nothing about whether the protocol was obeyed. They're independent
> properties, and that run separates them."

That sentence &mdash; *independent properties* &mdash; is the one to have word
perfect. It is the whole reason protocol assertions exist.

### "Why would you break your own driver?"

> "To prove the checker works. An assertion you've never seen fail is one you
> don't know is wired up. My plan lists six defects to inject, each naming the
> mechanism that has to catch it &mdash; that one is in the driver rather than
> the design, because VALID is master-driven and no slave bug could ever violate
> it."

### "What is it you're verifying, exactly?"

They skipped the context because you did. One sentence, then stop.

> "An AXI4-Lite peripheral subsystem &mdash; a register file with mixed access
> policies and a small memory. Deliberately small, so the effort goes into the
> methodology rather than the design."

If they're still listening after that, you are effectively into the 90-second
version. Go there.

---

## Follow-ups to the 90-second version

The long version front-loads the findings, so these probe *depth* rather than
*what happened*. Roughly in order of likelihood.

### "Did you find any real bugs in the *design*?"

The honest answer is strong. Do not dodge it.

> "No &mdash; all three genuine finds were in the testbench, not the RTL. Which I
> think is the more interesting result. The RTL is small and I wrote it from a
> specification I'd already corrected, so it had few places to hide a bug. The
> testbench is four times larger, was written under time pressure, and had
> nothing checking it except itself. So that's where the bugs were."

Then, if they are still with you:

> "And none of the three was a missed detection. Each was false confidence of a
> different kind &mdash; a metric that couldn't fail, a checker that cried wolf
> on correct hardware, and a test suite that had been passing on timing luck for
> eleven days."

That last clause usually gets a reaction.

### "Why is the RTL so simple?"

> "Because a bigger design would have eaten the time. Bursts and multiple
> outstanding transactions bring reorder buffers and response queues, and I'd
> have spent the project debugging those instead of building a scoreboard and a
> coverage model. It's a scope decision and it's written down as one &mdash;
> the README lists it next to the reason."

### "How did you find the cover-point bug?"

> "By reading the hit count and not believing it. My bench contains exactly one
> W-before-AW case, and the counter said ten. That gap is the whole bug &mdash;
> the property used an unbounded delay, so it was matching across transactions.
> The W of one and the AW of another satisfied it."

This is a good answer because it shows the *habit*, not the fix.

### "What's your coverage?"

Do not say a single number.

> "Six of eight groups at a hundred percent on the directed test. The two that
> aren't are structural &mdash; there's no interconnect yet, so DECERR and routed
> memory traffic are unreachable by any stimulus. Both are written up with the
> reason. My plan says an uncovered bin needs a justification in writing and that
> 'we ran out of time' doesn't count, so that's the standard I held it to."

### "How do you know your monitor is really independent?"

> "It has no handle to the driver at all &mdash; it only sees the read-only
> clocking block. And I check it: the sequence counts what it issued, the monitor
> counts pin handshakes, the scoreboard counts analysis-port arrivals. Three
> numbers along paths that share no state. If the monitor were echoing the driver
> they'd agree trivially and prove nothing, which is exactly why it can't reach
> it."

### "What would you do differently?"

> "Write the driver from the working non-UVM bench instead of from my design
> notes. Every task in the sanity bench aligns to a clock edge before driving.
> I dropped that in the UVM driver without noticing it was load-bearing, and it
> passed for eleven days on timing luck before a second DUT shifted the schedule
> and exposed it."

### "Which simulator?"

> "Cadence Xcelium on EDA Playground for UVM, Verilator and Icarus locally for
> the RTL and assertions. Aldec Riviera compiles UVM there but can't simulate it
> on the free tier &mdash; I found that by trying it, and it's in the tooling
> notes with the exact error."

### "What's next?"

> "Interconnect and address decode in September, which unblocks DECERR and the
> two open coverage bins. RAL in October, generated from a YAML register
> description rather than hand-written, so the RTL bank, the model and the docs
> can't drift apart. Then coverage closure and a formal experiment."

### If someone asks something you don't know

> "I don't know &mdash; I haven't looked at that."

Say it plainly and move on. A student who says "I don't know" once is credible
for everything else they said. A student who bluffs once is not credible for
anything.

---

## Reading the person in front of you

**A practising DV engineer.** Go straight to the findings; skip the component
list, they can infer it. They will probe the cover-property story and the
monitor independence. These are the best conversations available at the booth
&mdash; give them time and let them ask.

**A recruiter or hiring manager.** They want to know you can do the job and
communicate about it. The 90-second version as written, then the one-pager. The
scope-honesty line lands hardest with this group, because they have spent the
day hearing inflated claims.

**Another student.** Be generous. Explain the cover-property bug properly
&mdash; it's a genuinely useful thing to learn and costs you nothing. This is
also the group most likely to remember you.

---

## Practical

- **Record the 90-second version once on your phone.** Play it back. You are
  listening for pace and for the places you say "um" &mdash; those are the
  sentences you don't believe yet.
- **Rehearse the 20-second version more than the 90.** It is the one you will
  use most, and it is the one that decides whether the other happens.
- **Practise stopping.** Say the last line, then close your mouth. Count to
  three silently.
- **Carry the one-pager face up.** The headline and the findings block are
  readable at arm's length, which is often all the reading anyone does.
- **Know two numbers cold: ten to one, and thirty-one of thirty-one.** If you
  fumble a number the whole story loses its footing.
- **Do not open a laptop unless asked.** The one-pager is the artifact. Code on
  a screen at a booth is a conversation-ender, not a demo.

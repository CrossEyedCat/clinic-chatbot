# -*- coding: utf-8 -*-
"""Custom actions for the BrightCare Clinic assistant (appointment form)."""
import re
import hashlib
from typing import Any, Dict, List, Text

from rasa_sdk import Action, Tracker, FormValidationAction
from rasa_sdk.executor import CollectingDispatcher
from rasa_sdk.types import DomainDict

SPECIALTIES = {
    "gp": "general practitioner",
    "general practitioner": "general practitioner",
    "family doctor": "general practitioner",
    "cardiology": "cardiology",
    "cardiologist": "cardiology",
    "heart doctor": "cardiology",
    "dermatology": "dermatology",
    "dermatologist": "dermatology",
    "skin doctor": "dermatology",
    "paediatrics": "paediatrics",
    "paediatrician": "paediatrics",
    "pediatrician": "paediatrics",
    "children's doctor": "paediatrics",
    "physiotherapy": "physiotherapy",
    "physiotherapist": "physiotherapy",
}

PHONE_RE = re.compile(r"[\+0-9][0-9\-\s\(\)]{6,}[0-9]")
DATE_HINT_RE = re.compile(
    r"\d|monday|tuesday|wednesday|thursday|friday|saturday|sunday|"
    r"today|tomorrow|morning|afternoon|evening|next week|"
    r"january|february|march|april|may|june|july|august|september|october|november|december",
    re.IGNORECASE,
)


class ValidateAppointmentForm(FormValidationAction):
    def name(self) -> Text:
        return "validate_appointment_form"

    def validate_specialty(
        self, value: Text, dispatcher: CollectingDispatcher,
        tracker: Tracker, domain: DomainDict,
    ) -> Dict[Text, Any]:
        if value:
            norm = SPECIALTIES.get(value.strip().lower())
            if norm:
                return {"specialty": norm}
        dispatcher.utter_message(
            text="We don't have that specialty. Please choose one of: "
                 "GP, cardiology, dermatology, paediatrics, physiotherapy."
        )
        return {"specialty": None}

    def validate_appointment_date(
        self, value: Text, dispatcher: CollectingDispatcher,
        tracker: Tracker, domain: DomainDict,
    ) -> Dict[Text, Any]:
        # A phone-like reply (many digits, no time colon, no date words) is not a date
        has_date_word = bool(value) and bool(re.search(
            r"monday|tuesday|wednesday|thursday|friday|saturday|sunday|today|tomorrow|"
            r"morning|afternoon|evening|next|january|february|march|april|may|june|july|"
            r"august|september|october|november|december", value, re.IGNORECASE))
        looks_like_phone = (bool(value) and sum(c.isdigit() for c in value) >= 7
                            and ":" not in value and not has_date_word)
        if value and len(value.strip()) >= 3 and DATE_HINT_RE.search(value) and not looks_like_phone:
            return {"appointment_date": value.strip()}
        dispatcher.utter_message(
            text="Sorry, I couldn't read that as a date. "
                 "Try something like 'next Tuesday morning' or '12 August 15:00'."
        )
        return {"appointment_date": None}

    def validate_patient_name(
        self, value: Text, dispatcher: CollectingDispatcher,
        tracker: Tracker, domain: DomainDict,
    ) -> Dict[Text, Any]:
        v = (value or "").strip()
        letters = re.sub(r"[^A-Za-zÀ-ÿЀ-ӿ' \-]", "", v)
        if len(letters.replace(" ", "")) >= 2 and len(v) <= 60:
            return {"patient_name": v.title()}
        dispatcher.utter_message(text="That doesn't look like a name — could you type the patient's full name?")
        return {"patient_name": None}

    def validate_phone_number(
        self, value: Text, dispatcher: CollectingDispatcher,
        tracker: Tracker, domain: DomainDict,
    ) -> Dict[Text, Any]:
        v = (value or "").strip()
        m = PHONE_RE.search(v)
        if m and sum(c.isdigit() for c in m.group()) >= 7:
            return {"phone_number": m.group().strip()}
        dispatcher.utter_message(
            text="That phone number doesn't look right — please include at least 7 digits, e.g. +49 30 1234567."
        )
        return {"phone_number": None}


class ActionSubmitAppointment(Action):
    def name(self) -> Text:
        return "action_submit_appointment"

    def run(
        self, dispatcher: CollectingDispatcher,
        tracker: Tracker, domain: DomainDict,
    ) -> List[Dict[Text, Any]]:
        specialty = tracker.get_slot("specialty") or "GP"
        date = tracker.get_slot("appointment_date") or "-"
        name = tracker.get_slot("patient_name") or "-"
        phone = tracker.get_slot("phone_number") or "-"
        ref = "BC-" + hashlib.sha1(f"{name}|{date}|{specialty}".encode()).hexdigest()[:6].upper()
        dispatcher.utter_message(
            text=(
                "✅ Your appointment request has been recorded:\n"
                f"• Specialty: {specialty}\n"
                f"• Preferred time: {date}\n"
                f"• Patient: {name}\n"
                f"• Phone: {phone}\n"
                f"• Reference: {ref}\n"
                "Reception will call you within one working day to confirm the exact slot. "
                "If anything changes, call +49 30 555 0123 and quote your reference."
            )
        )
        return []
